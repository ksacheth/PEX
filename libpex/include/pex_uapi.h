#ifndef PEX_UAPI_H
#define PEX_UAPI_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define PEX_DEVICE_NAME "pex"
#define PEX_DEVICE_PATH "/dev/pex"
#define PEX_MAX_NAME_LEN 64

enum pex_policy_flags {
    PEX_POLICY_OWNER_THREAD_ONLY = (1u << 0),
    PEX_POLICY_NO_FORK_INHERIT = (1u << 1),
};

enum pex_fault_type {
    PEX_FAULT_NONE = 0,
    PEX_FAULT_MEM_ACCESS = 1,
    PEX_FAULT_CROSS_THREAD = 2,
    PEX_FAULT_BAD_STATE = 3,
    PEX_FAULT_BAD_OWNER = 4,
};

struct pex_create_req {
    __u64 size;
    __u32 policy_flags;
    __u32 reserved;
    __s32 out_ctx_id;
    __u32 out_reserved;
    char name[PEX_MAX_NAME_LEN];
};

struct pex_ctx_req {
    __s32 ctx_id;
    __s32 reserved;
};

struct pex_ctx_info {
    __s32 ctx_id;
    __s32 owner_tgid;
    __s32 owner_tid;
    __u32 active;
    __u32 policy_flags;
    __u64 size;
    __u64 total_entries;
    __u64 total_exits;
    __u64 total_faults;
    __u64 total_ns;
};

struct pex_fault_event {
    __s32 ctx_id;
    __s32 pid;
    __s32 tid;
    __u32 fault_type;
    __u32 reserved;
    __u64 fault_addr;
    __u64 ts_ns;
};

#define PEX_IOCTL_MAGIC 'P'
#define PEX_IOCTL_CREATE_CTX _IOWR(PEX_IOCTL_MAGIC, 1, struct pex_create_req)
#define PEX_IOCTL_DESTROY_CTX _IOW(PEX_IOCTL_MAGIC, 2, struct pex_ctx_req)
#define PEX_IOCTL_ENTER_CTX _IOW(PEX_IOCTL_MAGIC, 3, struct pex_ctx_req)
#define PEX_IOCTL_EXIT_CTX _IOW(PEX_IOCTL_MAGIC, 4, struct pex_ctx_req)
#define PEX_IOCTL_GET_CTX_INFO _IOWR(PEX_IOCTL_MAGIC, 5, struct pex_ctx_info)

#endif
