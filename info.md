# Working With the Control Group
## Mount Cgroup
```
mkdir cgroup
sudo mount -t cgroup -o memory memory ./cgroup
```

## Create Cgroup
```
sudo cgcreate -a $USER -t $USER -g memory:ginkgo
```

## Configure Cgroup
```
echo 2G > cgroup/ginkgo/memory.limit_in_bytes
echo 1 > cgroup/ginkgo/memory.oom_control
echo 0 > cgroup/ginkgo/memory.swappiness
```

## Run Cgroup
```
cgexec -g memory:ginkgo ./mem
```

## Clean-up
```
sudo cgdelete memory:ginkgo
sudo umount cgroup
```

# Notes
### `memory.oom_control`
```
oom_kill_disable # 0 or 1, if killing (9) is disabled or not)
under_oom 0 # 0 or 1, if a process is paused due to trying to allocator more memory than available
oom_kill 2 # kill count
```

### `memory.pressure_level`
`memory.pressure_level` doesn't apppear to have permissions on Ubuntu 20.04 or Centos 7.
```
---------- 1 shadeops root 0 Feb 19 23:10 memory.pressure_level
```
Might be possible to enable on boot or through some other kernel configuration?


### `memory.memsw.limit_in_bytes`
Is the combined limit of memory and swap. So roughly to limit swap size you could
do `swap_limit = memory.memsw.limit_in_bytes - memory.limit_in_bytes`

This does not exist by default in Ubuntu 20.04, and needs to be enabled with the
kernel boot parameter `swapaccount=1`. In newer versions of the kernel this now
always one and no longer an option.

### `notify_on_release`
This can be used to auto clean up cgroups, but the script for doing so can only reside
in the root of the control (as `release_agent`).
So not easy to do from user land.

### Setting up a OOM Event Listener


# Scenarios

## App Allocates 3GB of Memory

### No Swapping

```
echo 0 > cgroup/ginkgo/memory.swappiness
echo 2G > cgroup/ginkgo/memory.limit_in_bytes
echo 1 > cgroup/ginkgo/memory.oom_control
```

Process will go to sleep and `memory.oom_control.under_oom` is set to 1

### Swapping

```
echo 60 > cgroup/ginkgo/memory.swappiness
echo 2G > cgroup/ginkgo/memory.limit_in_bytes
echo 1 > cgroup/ginkgo/memory.oom_control
```

Process will use 2GB of resident memory, and 1GB of swap.

# References
* [cgroup v1](https://www.kernel.org/doc/Documentation/cgroup-v1/cgroups.txt)
* [cgroup v1 memory](https://www.kernel.org/doc/Documentation/cgroup-v1/memory.txt)
* [cgroup\_event\_listener](https://github.com/torvalds/linux/blob/v6.2/tools/cgroup/cgroup_event_listener.c)

