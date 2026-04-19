#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/fs.h>
#include <linux/hashtable.h>
#include <linux/init.h>
#include <linux/ioctl.h>
#include <linux/kernel.h>
#include <linux/kref.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pid.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/timekeeping.h>
#include <linux/uaccess.h>
#include <linux/version.h>
#include <linux/vmalloc.h>

#include "../libpex/include/pex_uapi.h"

#define PEX_CTX_TABLE_BITS 6

struct pex_context {
    struct hlist_node hnode;
    struct kref refcount;
    struct mutex lock;
    int ctx_id;
    pid_t owner_tgid;
    pid_t owner_tid;
    u32 policy_flags;
    bool active;
    u64 size;
    void *kbuf;
    u64 total_entries;
    u64 total_exits;
    u64 total_faults;
    u64 enter_ns;
    u64 total_ns;
    char name[PEX_MAX_NAME_LEN];
    unsigned long mapped_start;
    unsigned long mapped_len;
    struct mm_struct *mapped_mm;
};

static DEFINE_HASHTABLE(g_ctx_table, PEX_CTX_TABLE_BITS);
static DEFINE_SPINLOCK(g_ctx_table_lock);
static atomic_t g_next_ctx_id = ATOMIC_INIT(1);
static struct class *g_pex_class;
static dev_t g_pex_devt;
static struct cdev g_pex_cdev;
static struct proc_dir_entry *g_proc_root;
static atomic64_t g_live_contexts = ATOMIC64_INIT(0);
static atomic64_t g_active_contexts = ATOMIC64_INIT(0);
static atomic64_t g_total_faults = ATOMIC64_INIT(0);

static void pex_ctx_release(struct kref *ref)
{
    struct pex_context *ctx = container_of(ref, struct pex_context, refcount);

    if (ctx->mapped_mm)
        mmput(ctx->mapped_mm);
    vfree(ctx->kbuf);
    kfree(ctx);
}

static struct pex_context *pex_ctx_get_locked(int ctx_id)
{
    struct pex_context *ctx;

    hash_for_each_possible(g_ctx_table, ctx, hnode, (unsigned long)ctx_id) {
        if (ctx->ctx_id == ctx_id) {
            kref_get(&ctx->refcount);
            return ctx;
        }
    }
    return NULL;
}

static void pex_log_fault(struct pex_context *ctx, u32 fault_type, unsigned long addr)
{
    if (ctx)
        ctx->total_faults++;
    atomic64_inc(&g_total_faults);
    pr_warn("pex: fault ctx=%d pid=%d tid=%d type=%u addr=0x%lx\n",
        ctx ? ctx->ctx_id : -1, task_tgid_nr(current), task_pid_nr(current), fault_type, addr);
}

static int pex_ctx_create(struct pex_create_req __user *argp)
{
    struct pex_create_req req;
    struct pex_context *ctx;
    unsigned long flags;
    int id;

    if (copy_from_user(&req, argp, sizeof(req)))
        return -EFAULT;
    if (!req.size || req.size > (1ULL << 30))
        return -EINVAL;

    ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
    if (!ctx)
        return -ENOMEM;

    ctx->kbuf = vmalloc_user(req.size);
    if (!ctx->kbuf) {
        kfree(ctx);
        return -ENOMEM;
    }

    kref_init(&ctx->refcount);
    mutex_init(&ctx->lock);
    id = atomic_inc_return(&g_next_ctx_id);
    ctx->ctx_id = id;
    ctx->owner_tgid = task_tgid_nr(current);
    ctx->owner_tid = task_pid_nr(current);
    ctx->policy_flags = req.policy_flags;
    ctx->size = req.size;
    strscpy(ctx->name, req.name, sizeof(ctx->name));

    spin_lock_irqsave(&g_ctx_table_lock, flags);
    hash_add(g_ctx_table, &ctx->hnode, (unsigned long)ctx->ctx_id);
    spin_unlock_irqrestore(&g_ctx_table_lock, flags);
    atomic64_inc(&g_live_contexts);

    req.out_ctx_id = ctx->ctx_id;
    req.out_reserved = 0;

    if (copy_to_user(argp, &req, sizeof(req)))
        return -EFAULT;
    return 0;
}

static int pex_ctx_destroy(struct pex_ctx_req __user *argp)
{
    struct pex_ctx_req req;
    struct pex_context *ctx;
    struct hlist_node *tmp;
    unsigned long flags;

    if (copy_from_user(&req, argp, sizeof(req)))
        return -EFAULT;

    spin_lock_irqsave(&g_ctx_table_lock, flags);
    hash_for_each_possible_safe(g_ctx_table, ctx, tmp, hnode, (unsigned long)req.ctx_id) {
        u64 now;

        if (ctx->ctx_id != req.ctx_id)
            continue;

        hash_del(&ctx->hnode);
        spin_unlock_irqrestore(&g_ctx_table_lock, flags);

        mutex_lock(&ctx->lock);
        if (ctx->owner_tgid != task_tgid_nr(current)) {
            pex_log_fault(ctx, PEX_FAULT_BAD_OWNER, 0);
            mutex_unlock(&ctx->lock);
            spin_lock_irqsave(&g_ctx_table_lock, flags);
            hash_add(g_ctx_table, &ctx->hnode, (unsigned long)ctx->ctx_id);
            spin_unlock_irqrestore(&g_ctx_table_lock, flags);
            return -EPERM;
        }

        if (ctx->active) {
            now = ktime_get_ns();
            if (now > ctx->enter_ns)
                ctx->total_ns += (now - ctx->enter_ns);
            ctx->active = false;
            atomic64_dec(&g_active_contexts);
        }
        mutex_unlock(&ctx->lock);

        atomic64_dec(&g_live_contexts);
        kref_put(&ctx->refcount, pex_ctx_release);
        return 0;
    }
    spin_unlock_irqrestore(&g_ctx_table_lock, flags);

    return -ENOENT;
}

static int pex_ctx_enter(struct pex_ctx_req __user *argp)
{
    struct pex_ctx_req req;
    struct pex_context *ctx;
    unsigned long flags;
    int ret = 0;

    if (copy_from_user(&req, argp, sizeof(req)))
        return -EFAULT;

    spin_lock_irqsave(&g_ctx_table_lock, flags);
    ctx = pex_ctx_get_locked(req.ctx_id);
    spin_unlock_irqrestore(&g_ctx_table_lock, flags);
    if (!ctx)
        return -ENOENT;

    mutex_lock(&ctx->lock);
    if (ctx->owner_tgid != task_tgid_nr(current)) {
        pex_log_fault(ctx, PEX_FAULT_BAD_OWNER, 0);
        ret = -EPERM;
        goto out;
    }
    if ((ctx->policy_flags & PEX_POLICY_OWNER_THREAD_ONLY) &&
        ctx->owner_tid != task_pid_nr(current)) {
        pex_log_fault(ctx, PEX_FAULT_CROSS_THREAD, 0);
        ret = -EPERM;
        goto out;
    }
    if (ctx->active) {
        pex_log_fault(ctx, PEX_FAULT_BAD_STATE, 0);
        ret = -EBUSY;
        goto out;
    }

    ctx->active = true;
    ctx->total_entries++;
    ctx->enter_ns = ktime_get_ns();
    atomic64_inc(&g_active_contexts);

out:
    mutex_unlock(&ctx->lock);
    kref_put(&ctx->refcount, pex_ctx_release);
    return ret;
}

static int pex_ctx_exit(struct pex_ctx_req __user *argp)
{
    struct pex_ctx_req req;
    struct pex_context *ctx;
    unsigned long flags;
    int ret = 0;
    u64 now;

    if (copy_from_user(&req, argp, sizeof(req)))
        return -EFAULT;

    spin_lock_irqsave(&g_ctx_table_lock, flags);
    ctx = pex_ctx_get_locked(req.ctx_id);
    spin_unlock_irqrestore(&g_ctx_table_lock, flags);
    if (!ctx)
        return -ENOENT;

    mutex_lock(&ctx->lock);
    if (!ctx->active) {
        pex_log_fault(ctx, PEX_FAULT_BAD_STATE, 0);
        ret = -EINVAL;
        goto out;
    }
    if (ctx->owner_tid != task_pid_nr(current)) {
        pex_log_fault(ctx, PEX_FAULT_CROSS_THREAD, 0);
        ret = -EPERM;
        goto out;
    }

    now = ktime_get_ns();
    ctx->active = false;
    ctx->total_exits++;
    if (now > ctx->enter_ns)
        ctx->total_ns += (now - ctx->enter_ns);
    atomic64_dec(&g_active_contexts);

    if (ctx->mapped_mm && ctx->mapped_start && ctx->mapped_len) {
        struct vm_area_struct *vma;

        mmap_write_lock(ctx->mapped_mm);
        vma = find_vma(ctx->mapped_mm, ctx->mapped_start);
        if (vma && vma->vm_start == ctx->mapped_start && vma->vm_private_data == ctx)
            zap_vma_ptes(vma, ctx->mapped_start, ctx->mapped_len);
        mmap_write_unlock(ctx->mapped_mm);
    }

out:
    mutex_unlock(&ctx->lock);
    kref_put(&ctx->refcount, pex_ctx_release);
    return ret;
}

static int pex_ctx_get_info(struct pex_ctx_info __user *argp)
{
    struct pex_ctx_info info;
    struct pex_context *ctx;
    unsigned long flags;

    if (copy_from_user(&info, argp, sizeof(info)))
        return -EFAULT;

    spin_lock_irqsave(&g_ctx_table_lock, flags);
    ctx = pex_ctx_get_locked(info.ctx_id);
    spin_unlock_irqrestore(&g_ctx_table_lock, flags);
    if (!ctx)
        return -ENOENT;

    mutex_lock(&ctx->lock);
    info.owner_tgid = ctx->owner_tgid;
    info.owner_tid = ctx->owner_tid;
    info.active = ctx->active;
    info.policy_flags = ctx->policy_flags;
    info.size = ctx->size;
    info.total_entries = ctx->total_entries;
    info.total_exits = ctx->total_exits;
    info.total_faults = ctx->total_faults;
    info.total_ns = ctx->total_ns;
    mutex_unlock(&ctx->lock);

    kref_put(&ctx->refcount, pex_ctx_release);
    if (copy_to_user(argp, &info, sizeof(info)))
        return -EFAULT;
    return 0;
}

static long pex_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    switch (cmd) {
    case PEX_IOCTL_CREATE_CTX:
        return pex_ctx_create((struct pex_create_req __user *)arg);
    case PEX_IOCTL_DESTROY_CTX:
        return pex_ctx_destroy((struct pex_ctx_req __user *)arg);
    case PEX_IOCTL_ENTER_CTX:
        return pex_ctx_enter((struct pex_ctx_req __user *)arg);
    case PEX_IOCTL_EXIT_CTX:
        return pex_ctx_exit((struct pex_ctx_req __user *)arg);
    case PEX_IOCTL_GET_CTX_INFO:
        return pex_ctx_get_info((struct pex_ctx_info __user *)arg);
    default:
        return -ENOTTY;
    }
}

static ssize_t pex_proc_read(struct file *file, char __user *ubuf, size_t count, loff_t *ppos)
{
    char *buf;
    int len;
    unsigned long flags;
    int bkt;
    struct pex_context *ctx;

    buf = kzalloc(PAGE_SIZE, GFP_KERNEL);
    if (!buf)
        return -ENOMEM;

    len = scnprintf(buf, PAGE_SIZE,
        "live_contexts=%lld\nactive_contexts=%lld\ntotal_faults=%lld\n",
        atomic64_read(&g_live_contexts),
        atomic64_read(&g_active_contexts),
        atomic64_read(&g_total_faults));

    spin_lock_irqsave(&g_ctx_table_lock, flags);
    hash_for_each(g_ctx_table, bkt, ctx, hnode) {
        len += scnprintf(buf + len, PAGE_SIZE - len,
            "ctx=%d owner=%d:%d active=%u entries=%llu exits=%llu faults=%llu ns=%llu size=%llu name=%s\n",
            ctx->ctx_id, ctx->owner_tgid, ctx->owner_tid, ctx->active,
            ctx->total_entries, ctx->total_exits, ctx->total_faults, ctx->total_ns,
            ctx->size, ctx->name);
        if (len >= PAGE_SIZE - 160)
            break;
    }
    spin_unlock_irqrestore(&g_ctx_table_lock, flags);

    len = simple_read_from_buffer(ubuf, count, ppos, buf, len);
    kfree(buf);
    return len;
}

static const struct proc_ops pex_proc_ops = {
    .proc_read = pex_proc_read,
};

static vm_fault_t pex_vma_fault(struct vm_fault *vmf)
{
    struct vm_area_struct *vma = vmf->vma;
    struct pex_context *ctx = vma->vm_private_data;
    unsigned long offset;
    struct page *page;

    if (!ctx)
        return VM_FAULT_SIGSEGV;

    mutex_lock(&ctx->lock);
    if (!ctx->active || ctx->owner_tid != task_pid_nr(current)) {
        pex_log_fault(ctx, PEX_FAULT_MEM_ACCESS, vmf->address);
        mutex_unlock(&ctx->lock);
        return VM_FAULT_SIGSEGV;
    }

    offset = vmf->address - vma->vm_start;
    if (offset >= ctx->size) {
        mutex_unlock(&ctx->lock);
        return VM_FAULT_SIGBUS;
    }

    page = vmalloc_to_page((char *)ctx->kbuf + offset);
    if (!page) {
        mutex_unlock(&ctx->lock);
        return VM_FAULT_SIGBUS;
    }

    get_page(page);
    vmf->page = page;
    mutex_unlock(&ctx->lock);
    return 0;
}

static void pex_vma_close(struct vm_area_struct *vma)
{
    struct pex_context *ctx = vma->vm_private_data;

    if (!ctx)
        return;

    mutex_lock(&ctx->lock);
    if (ctx->mapped_mm == current->mm &&
        ctx->mapped_start == vma->vm_start &&
        ctx->mapped_len == (vma->vm_end - vma->vm_start)) {
        mmput(ctx->mapped_mm);
        ctx->mapped_mm = NULL;
        ctx->mapped_start = 0;
        ctx->mapped_len = 0;
    }
    mutex_unlock(&ctx->lock);
    kref_put(&ctx->refcount, pex_ctx_release);
}

static const struct vm_operations_struct pex_vm_ops = {
    .fault = pex_vma_fault,
    .close = pex_vma_close,
};

static int pex_mmap(struct file *file, struct vm_area_struct *vma)
{
    int ctx_id = (int)vma->vm_pgoff;
    struct pex_context *ctx;
    unsigned long flags;
    unsigned long len = vma->vm_end - vma->vm_start;

    spin_lock_irqsave(&g_ctx_table_lock, flags);
    ctx = pex_ctx_get_locked(ctx_id);
    spin_unlock_irqrestore(&g_ctx_table_lock, flags);
    if (!ctx)
        return -ENOENT;

    mutex_lock(&ctx->lock);
    if (ctx->owner_tgid != task_tgid_nr(current)) {
        mutex_unlock(&ctx->lock);
        kref_put(&ctx->refcount, pex_ctx_release);
        return -EPERM;
    }
    if (len > ctx->size || len == 0 || !PAGE_ALIGNED(len)) {
        mutex_unlock(&ctx->lock);
        kref_put(&ctx->refcount, pex_ctx_release);
        return -EINVAL;
    }
    if (ctx->mapped_mm) {
        mutex_unlock(&ctx->lock);
        kref_put(&ctx->refcount, pex_ctx_release);
        return -EBUSY;
    }

    ctx->mapped_mm = current->mm;
    mmget(ctx->mapped_mm);
    ctx->mapped_start = vma->vm_start;
    ctx->mapped_len = len;

    #if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
    vm_flags_set(vma, VM_DONTCOPY | VM_DONTDUMP);
#else
    vma->vm_flags |= VM_DONTCOPY | VM_DONTDUMP;
#endif
    vma->vm_ops = &pex_vm_ops;
    vma->vm_private_data = ctx;
    mutex_unlock(&ctx->lock);
    return 0;
}

static const struct file_operations pex_fops = {
    .owner = THIS_MODULE,
    .unlocked_ioctl = pex_ioctl,
    .mmap = pex_mmap,
#ifdef CONFIG_COMPAT
    .compat_ioctl = pex_ioctl,
#endif
};

static int __init pex_init(void)
{
    int ret;
    struct device *pex_device;

    hash_init(g_ctx_table);

    ret = alloc_chrdev_region(&g_pex_devt, 0, 1, PEX_DEVICE_NAME);
    if (ret)
        return ret;

    cdev_init(&g_pex_cdev, &pex_fops);
    g_pex_cdev.owner = THIS_MODULE;
    ret = cdev_add(&g_pex_cdev, g_pex_devt, 1);
    if (ret)
        goto err_chrdev;

    #if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0)
    g_pex_class = class_create(PEX_DEVICE_NAME);
#else
    g_pex_class = class_create(THIS_MODULE, PEX_DEVICE_NAME);
#endif
    if (IS_ERR(g_pex_class)) {
        ret = PTR_ERR(g_pex_class);
        goto err_cdev;
    }

    if (IS_ERR(device_create(g_pex_class, NULL, g_pex_devt, NULL, PEX_DEVICE_NAME))) {
        ret = -ENOMEM;
        goto err_class;
    }

    g_proc_root = proc_create("pex_stats", 0444, NULL, &pex_proc_ops);
    if (!g_proc_root) {
        ret = -ENOMEM;
        goto err_device;
    }

    pr_info("pex: module loaded\n");
    return 0;

err_device:
    device_destroy(g_pex_class, g_pex_devt);
err_class:
    class_destroy(g_pex_class);
err_cdev:
    cdev_del(&g_pex_cdev);
err_chrdev:
    unregister_chrdev_region(g_pex_devt, 1);
    return ret;
}

static void __exit pex_exit(void)
{
    struct pex_context *ctx;
    struct hlist_node *tmp;
    unsigned long flags;
    int bkt;

    if (g_proc_root)
        proc_remove(g_proc_root);
    device_destroy(g_pex_class, g_pex_devt);
    class_destroy(g_pex_class);
    cdev_del(&g_pex_cdev);
    unregister_chrdev_region(g_pex_devt, 1);

    spin_lock_irqsave(&g_ctx_table_lock, flags);
    hash_for_each_safe(g_ctx_table, bkt, tmp, ctx, hnode) {
        hash_del(&ctx->hnode);
        kref_put(&ctx->refcount, pex_ctx_release);
    }
    spin_unlock_irqrestore(&g_ctx_table_lock, flags);

    pr_info("pex: module unloaded\n");
}

module_init(pex_init);
module_exit(pex_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("SoftTEE");
MODULE_DESCRIPTION("Kernel-Assisted Protected Execution Subsystem (PEX)");
