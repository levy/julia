# No preemption inside the event loop

The other half of "avoid the OS biting us" (see
`../done/memory-regions-hil-prefault.md` for the memory half). A time-shared
task (`SCHED_OTHER`) is preempted by any other runnable task; the matrix
attributes such preemptions per 10 000-event block and keeps the run with
the fewest, which is honest but not the best case. The best case a HIL
simulator arranges is a real-time class on an isolated core, and the log
must prove it got one.

## What the runtime side does (done)

- [x] The driver prints `scheduler SCHED_FIFO priority N` (or
      `SCHED_OTHER`, with the warning) from `sched_getscheduler` and
      `sched_getparam`, and `memory locked yes/no` from `mlockall`.
- [x] `realworld.sh` runs every configuration under `chrt -f $RTPRIO`
      (default 50) when the machine grants a real-time class, else says so.

## What the machine must grant (root, the user's part): the isolated core

The user's choice (2026-09-01): the fully isolated setting — `isolcpus`,
`nohz_full`, `rcu_nocbs` — a kernel command line and a reboot. The kernel
7.0.0-30-generic has `CONFIG_NO_HZ_FULL`, `CONFIG_CPU_ISOLATION`,
`CONFIG_RCU_NOCB_CPU`, HZ=1000. CPU 13 and CPU 29 are the two threads of
core 13, so both are isolated and the loop runs on 29 with 13 idle.

1. `/etc/default/grub`:
   `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash isolcpus=domain,managed_irq,13,29 nohz_full=13,29 rcu_nocbs=13,29 irqaffinity=0-12,14-28,30-31"`
   then `sudo update-grub`. `domain` takes the two CPUs out of the
   scheduler domains (only a task pinned there runs there), `managed_irq`
   keeps managed device interrupts off them, `irqaffinity` puts the others
   elsewhere, `nohz_full` stops the tick while one task runs, `rcu_nocbs`
   moves the RCU callbacks away.
2. The limits, for every session including the IDE's (`pam_limits` is
   not in `common-session` here, so `limits.conf` alone does not reach
   it): in `/etc/systemd/system.conf` and `/etc/systemd/user.conf`
   `DefaultLimitRTPRIO=99` and `DefaultLimitMEMLOCK=infinity`; and in
   `/etc/security/limits.conf` `projectured - rtprio 99`,
   `projectured - memlock unlimited` for the PAM sessions.
3. No real-time throttling, persistent: `/etc/sysctl.d/99-hil.conf` with
   `kernel.sched_rt_runtime_us = -1`.
4. Reboot.

## After the reboot (the next session)

- [x] Checked after the reboot: `/proc/cmdline` holds the line; `/sys/devices/system/cpu/isolated`
      and `nohz_full` read `13,29`; `ulimit -r` = 99, `ulimit -l` =
      unlimited in a shell of the session; `sysctl kernel.sched_rt_runtime_us`
      = -1; `cat /proc/interrupts` shows CPU29 quiet.
## Then

- [x] `./realworld.sh` (CORE=29): every kept run says (first try, six of six)
      `SCHED_FIFO`, `memory locked yes`, `involuntary context switches 0`,
      `page faults 0`, and the raw maximum must equal the preemption-free one.
- [x] The documents: the environment section states the command line, the
      class, the lock, the throttle setting; the preemption paragraph says
      the attribution is the fallback for a machine without the isolation.
- [x] Commit and push.

## Result

Six of six runs at the first try: `SCHED_FIFO priority 50`, `memory
locked yes`, 0 involuntary switches, 0 page faults, raw max = preemption-free
max. Nine interrupts on CPU 29 across a whole run of about 3 s, four of
them the local timer: the tick is stopped. Stock recording-class p99.99
3.6 us → 691 ns (the old tail was the OS); stock max 4.0 / 3.9 ms (its
collections), census max 74 us (the census), no-census max 16 / 15 us (the
largest slice reset). Peak RSS now includes the locked image (1.2 GB).
