-- This is the actual system calls for Linux

local require, error, assert, tonumber, tostring,
setmetatable, pairs, ipairs, unpack, rawget, rawset,
pcall, type, table, string = 
require, error, assert, tonumber, tostring,
setmetatable, pairs, ipairs, unpack, rawget, rawset,
pcall, type, table, string

local abi = require "syscall.abi"

return function(S, hh, c, C, types)

local ret64, retnum, retfd, retbool, retptr, retiter = hh.ret64, hh.retnum, hh.retfd, hh.retbool, hh.retptr, hh.retiter

local ffi = require "ffi"
local errno = ffi.errno

local bit = require "syscall.bit"

local t, pt, s = types.t, types.pt, types.s

local h = require "syscall.helpers"

local istype, mktype, getfd = h.istype, h.mktype, h.getfd

if abi.abi32 then
  -- override open call with largefile -- TODO move this hack to c.lua instead
  function S.open(pathname, flags, mode)
    flags = bit.bor(c.O[flags], c.O.LARGEFILE)
    return retfd(C.open(pathname, flags, c.MODE[mode]))
  end
  function S.openat(dirfd, pathname, flags, mode)
    flags = bit.bor(c.O[flags], c.O.LARGEFILE)
    return retfd(C.openat(c.AT_FDCWD[dirfd], pathname, flags, c.MODE[mode]))
  end
  -- creat has no largefile flag so cannot be used
  function S.creat(pathname, mode) return S.open(pathname, "CREAT,WRONLY,TRUNC", mode) end
end

function S.pause() return retbool(C.pause()) end

function S.acct(filename) return retbool(C.acct(filename)) end

function S.getpriority(which, who)
  local ret, err = C.getpriority(c.PRIO[which], who or 0)
  if ret == -1 then return nil, t.error(err or errno()) end
  return 20 - ret -- adjust for kernel returned values as this is syscall not libc
end

-- we could allocate ptid, ctid, tls if required in flags instead. TODO add signal into flag parsing directly
function S.clone(flags, signal, stack, ptid, tls, ctid)
  flags = c.CLONE[flags] + c.SIG[signal or 0]
  return retnum(C.clone(flags, stack, ptid, tls, ctid))
end

if C.unshare then -- quite new, also not defined in rump yet
  function S.unshare(flags) return retbool(C.unshare(c.CLONE[flags])) end
end
if C.setns then
  function S.setns(fd, nstype) return retbool(C.setns(getfd(fd), c.CLONE[nstype])) end
end

-- note that this is not strictly the syscall that has some other arguments, but has same functionality
function S.reboot(cmd) return retbool(C.reboot(c.LINUX_REBOOT_CMD[cmd])) end

function S.wait(status)
  status = status or t.int1()
  local ret, err = C.wait(status)
  if ret == -1 then return nil, t.error(err or errno()) end
  return ret, nil, t.waitstatus(status[0])
end
function S.waitpid(pid, options, status) -- note order of arguments changed as rarely supply status
  status = status or t.int1()
  local ret, err = C.waitpid(c.WAIT[pid], status, c.W[options])
  if ret == -1 then return nil, t.error(err or errno()) end
  return ret, nil, t.waitstatus(status[0])
end
function S.waitid(idtype, id, options, infop) -- note order of args, as usually dont supply infop
  if not infop then infop = t.siginfo() end
  local ret, err = C.waitid(c.P[idtype], id or 0, infop, c.W[options])
  if ret == -1 then return nil, t.error(err or errno()) end
  return infop
end

function S.exit(status) C.exit_group(c.EXIT[status or 0]) end

function S.sync_file_range(fd, offset, count, flags)
  return retbool(C.sync_file_range(getfd(fd), offset, count, c.SYNC_FILE_RANGE[flags]))
end

function S.getcwd(buf, size)
  size = size or c.PATH_MAX
  buf = buf or t.buffer(size)
  local ret, err = C.getcwd(buf, size)
  if ret == -1 then return nil, t.error(err or errno()) end
  return ffi.string(buf)
end

function S.statfs(path)
  local st = t.statfs()
  local ret, err = C.statfs(path, st)
  if ret == -1 then return nil, t.error(err or errno()) end
  return st
end

function S.fstatfs(fd)
  local st = t.statfs()
  local ret, err = C.fstatfs(getfd(fd), st)
  if ret == -1 then return nil, t.error(err or errno()) end
  return st
end

function S.mremap(old_address, old_size, new_size, flags, new_address)
  return retptr(C.mremap(old_address, old_size, new_size, c.MREMAP[flags], new_address))
end
function S.fadvise(fd, advice, offset, len) -- note argument order TODO change back?
  return retbool(C.fadvise64(getfd(fd), offset or 0, len or 0, c.POSIX_FADV[advice]))
end
function S.fallocate(fd, mode, offset, len)
  return retbool(C.fallocate(getfd(fd), c.FALLOC_FL[mode], offset or 0, len))
end
function S.posix_fallocate(fd, offset, len) return S.fallocate(fd, 0, offset, len) end
function S.readahead(fd, offset, count) return retbool(C.readahead(getfd(fd), offset, count)) end

-- TODO change to type?
function S.uname()
  local u = t.utsname()
  local ret, err = C.uname(u)
  if ret == -1 then return nil, t.error(err or errno()) end
  return {sysname = ffi.string(u.sysname), nodename = ffi.string(u.nodename), release = ffi.string(u.release),
          version = ffi.string(u.version), machine = ffi.string(u.machine), domainname = ffi.string(u.domainname)}
end

function S.sethostname(s) -- only accept Lua string, do not see use case for buffer as well
  return retbool(C.sethostname(s, #s))
end

function S.setdomainname(s)
  return retbool(C.setdomainname(s, #s))
end

function S.settimeofday(tv) return retbool(C.settimeofday(tv, nil)) end

function S.time(time) return retnum(C.time(time)) end

function S.sysinfo(info)
  info = info or t.sysinfo()
  local ret, err = C.sysinfo(info)
  if ret == -1 then return nil, t.error(err or errno()) end
  return info
end

function S.signalfd(set, flags, fd) -- note different order of args, as fd usually empty. See also signalfd_read()
  set = mktype(t.sigset, set)
  if fd then fd = getfd(fd) else fd = -1 end
  return retfd(C.signalfd(fd, set, c.SFD[flags]))
end

-- note that syscall does return timeout remaining but libc does not, due to standard prototype TODO use syscall
-- note this is the only difference with NetBSD pollts, so could merge them
function S.ppoll(fds, timeout, set)
  if timeout then timeout = mktype(t.timespec, timeout) end
  if set then set = mktype(t.sigset, set) end
  return retnum(C.ppoll(fds.pfd, #fds, timeout, set))
end

function S.mount(source, target, fstype, mountflags, data)
  return retbool(C.mount(source or "none", target, fstype, c.MS[mountflags], data))
end

function S.umount(target, flags)
  return retbool(C.umount2(target, c.UMOUNT[flags]))
end

function S.prlimit(pid, resource, new_limit, old_limit)
  if new_limit then new_limit = mktype(t.rlimit, new_limit) end
  old_limit = old_limit or t.rlimit()
  local ret, err = C.prlimit64(pid or 0, c.RLIMIT[resource], new_limit, old_limit)
  if ret == -1 then return nil, t.error(err or errno()) end
  return old_limit
end

function S.epoll_create(flags)
  return retfd(C.epoll_create1(c.EPOLLCREATE[flags]))
end

function S.epoll_ctl(epfd, op, fd, event)
  if type(event) == "string" or type(event) == "number" then event = {events = event, fd = getfd(fd)} end
  event = mktype(t.epoll_event, event)
  return retbool(C.epoll_ctl(getfd(epfd), c.EPOLL_CTL[op], getfd(fd), event))
end

function S.epoll_wait(epfd, events, timeout)
  local ret, err = C.epoll_wait(getfd(epfd), events.ep, #events, timeout or -1)
  return retiter(ret, err, events.ep)
end

function S.epoll_pwait(epfd, events, timeout, sigmask)
  if sigmask then sigmask = mktype(t.sigset, sigmask) end
  local ret, err = C.epoll_pwait(getfd(epfd), events.ep, #events, timeout or -1, sigmask)
  return retiter(ret, err, events.ep)
end

function S.splice(fd_in, off_in, fd_out, off_out, len, flags)
  local offin, offout = off_in, off_out
  if off_in and not ffi.istype(t.off1, off_in) then
    offin = t.off1()
    offin[0] = off_in
  end
  if off_out and not ffi.istype(t.off1, off_out) then
    offout = t.off1()
    offout[0] = off_out
  end
  return retnum(C.splice(getfd(fd_in), offin, getfd(fd_out), offout, len, c.SPLICE_F[flags]))
end

function S.vmsplice(fd, iov, flags)
  iov = mktype(t.iovecs, iov)
  return retnum(C.vmsplice(getfd(fd), iov.iov, #iov, c.SPLICE_F[flags]))
end

function S.tee(fd_in, fd_out, len, flags)
  return retnum(C.tee(getfd(fd_in), getfd(fd_out), len, c.SPLICE_F[flags]))
end

function S.inotify_init(flags) return retfd(C.inotify_init1(c.IN_INIT[flags])) end
function S.inotify_add_watch(fd, pathname, mask) return retnum(C.inotify_add_watch(getfd(fd), pathname, c.IN[mask])) end
function S.inotify_rm_watch(fd, wd) return retbool(C.inotify_rm_watch(getfd(fd), wd)) end

function S.sendfile(out_fd, in_fd, offset, count)
  if type(offset) == "number" then
    offset = t.off1(offset)
  end
  return retnum(C.sendfile(getfd(out_fd), getfd(in_fd), offset, count))
end

function S.eventfd(initval, flags) return retfd(C.eventfd(initval or 0, c.EFD[flags])) end

function S.timerfd_create(clockid, flags)
  return retfd(C.timerfd_create(c.CLOCK[clockid], c.TFD[flags]))
end

function S.timerfd_settime(fd, flags, it, oldtime)
  oldtime = oldtime or t.itimerspec()
  local ret, err = C.timerfd_settime(getfd(fd), c.TFD_TIMER[flags or 0], mktype(t.itimerspec, it), oldtime)
  if ret == -1 then return nil, t.error(err or errno()) end
  return oldtime
end

function S.timerfd_gettime(fd, curr_value)
  curr_value = curr_value or t.itimerspec()
  local ret, err = C.timerfd_gettime(getfd(fd), curr_value)
  if ret == -1 then return nil, t.error(err or errno()) end
  return curr_value
end

function S.pivot_root(new_root, put_old) return retbool(C.pivot_root(new_root, put_old)) end

-- aio functions
function S.io_setup(nr_events)
  local ctx = t.aio_context1()
  local ret, err = C.io_setup(nr_events, ctx)
  if ret == -1 then return nil, t.error(err or errno()) end
  return ctx[0]
end

function S.io_destroy(ctx) return retbool(C.io_destroy(ctx)) end

function S.io_cancel(ctx, iocb, result)
  result = result or t.io_event()
  local ret, err = C.io_cancel(ctx, iocb, result)
  if ret == -1 then return nil, t.error(err or errno()) end
  return result
end

function S.io_getevents(ctx, min, events, timeout)
  if timeout then timeout = mktype(t.timespec, timeout) end
  local ret, err = C.io_getevents(ctx, min or events.count, events.count, events.ev, timeout)
  return retiter(ret, err, events.ev)
end

-- iocb must persist until retrieved (as we get pointer), so cannot be passed as table must take t.iocb_array
function S.io_submit(ctx, iocb)
  return retnum(C.io_submit(ctx, iocb.ptrs, iocb.nr))
end

-- TODO prctl should be in a seperate file like ioctl fnctl (this is a Linux only interface)
-- map for valid options for arg2
local prctlmap = {
  [c.PR.CAPBSET_READ] = c.CAP,
  [c.PR.CAPBSET_DROP] = c.CAP,
  [c.PR.SET_ENDIAN] = c.PR_ENDIAN,
  [c.PR.SET_FPEMU] = c.PR_FPEMU,
  [c.PR.SET_FPEXC] = c.PR_FP_EXC,
  [c.PR.SET_PDEATHSIG] = c.SIG,
  --[c.PR.SET_SECUREBITS] = c.SECBIT, -- TODO not defined yet
  [c.PR.SET_TIMING] = c.PR_TIMING,
  [c.PR.SET_TSC] = c.PR_TSC,
  [c.PR.SET_UNALIGN] = c.PR_UNALIGN,
  [c.PR.MCE_KILL] = c.PR_MCE_KILL,
  [c.PR.SET_SECCOMP] = c.SECCOMP_MODE,
  [c.PR.SET_NO_NEW_PRIVS] = h.booltoc,
}

local prctlrint = { -- returns an integer directly TODO add metatables to set names
  [c.PR.GET_DUMPABLE] = true,
  [c.PR.GET_KEEPCAPS] = true,
  [c.PR.CAPBSET_READ] = true,
  [c.PR.GET_TIMING] = true,
  [c.PR.GET_SECUREBITS] = true,
  [c.PR.MCE_KILL_GET] = true,
  [c.PR.GET_SECCOMP] = true,
  [c.PR.GET_NO_NEW_PRIVS] = true,
}

local prctlpint = { -- returns result in a location pointed to by arg2
  [c.PR.GET_ENDIAN] = true,
  [c.PR.GET_FPEMU] = true,
  [c.PR.GET_FPEXC] = true,
  [c.PR.GET_PDEATHSIG] = true,
  [c.PR.GET_UNALIGN] = true,
}

-- this is messy, TODO clean up, its own file see above
function S.prctl(option, arg2, arg3, arg4, arg5)
  local i, name
  option = c.PR[option]
  local m = prctlmap[option]
  if m then arg2 = m[arg2] end
  if option == c.PR.MCE_KILL and arg2 == c.PR_MCE_KILL.SET then
    arg3 = c.PR_MCE_KILL_OPT[arg3]
  elseif prctlpint[option] then
    i = t.int1()
    arg2 = ffi.cast(t.ulong, i)
  elseif option == c.PR.GET_NAME then
    name = t.buffer(16)
    arg2 = ffi.cast(t.ulong, name)
  elseif option == c.PR.SET_NAME then
    if type(arg2) == "string" then arg2 = ffi.cast(t.ulong, arg2) end
  elseif option == c.PR.SET_SECCOMP then
    arg3 = t.intptr(arg3 or 0)
  end
  local ret = C.prctl(option, arg2 or 0, arg3 or 0, arg4 or 0, arg5 or 0)
  if ret == -1 then return nil, t.error() end
  if prctlrint[option] then return ret end
  if prctlpint[option] then return i[0] end
  if option == c.PR.GET_NAME then
    if name[15] ~= 0 then return ffi.string(name, 16) end -- actually, 15 bytes seems to be longest, aways 0 terminated
    return ffi.string(name)
  end
  return true
end

function S.syslog(tp, buf, len)
  if not buf and (tp == 2 or tp == 3 or tp == 4) then
    if not len then
      -- this is the glibc name for the syslog syscall
      len = C.klogctl(10, nil, 0) -- get size so we can allocate buffer
      if len == -1 then return nil, t.error() end
    end
    buf = t.buffer(len)
  end
  local ret, err = C.klogctl(tp, buf or nil, len or 0)
  if ret == -1 then return nil, t.error(err or errno()) end
  if tp == 9 or tp == 10 then return tonumber(ret) end
  if tp == 2 or tp == 3 or tp == 4 then return ffi.string(buf, ret) end
  return true
end

function S.adjtimex(a)
  a = mktype(t.timex, a)
  local ret, err = C.adjtimex(a)
  if ret == -1 then return nil, t.error(err or errno()) end
  return t.adjtimex(ret, a)
end

function S.alarm(s) return C.alarm(s) end

function S.setreuid(ruid, euid) return retbool(C.setreuid(ruid, euid)) end
function S.setregid(rgid, egid) return retbool(C.setregid(rgid, egid)) end

function S.getresuid(ruid, euid, suid)
  ruid, euid, suid = ruid or t.uid1(), euid or t.uid1(), suid or t.uid1()
  local ret, err = C.getresuid(ruid, euid, suid)
  if ret == -1 then return nil, t.error(err or errno()) end
  return true, nil, ruid[0], euid[0], suid[0]
end
function S.getresgid(rgid, egid, sgid)
  rgid, egid, sgid = rgid or t.gid1(), egid or t.gid1(), sgid or t.gid1()
  local ret, err = C.getresgid(rgid, egid, sgid)
  if ret == -1 then return nil, t.error(err or errno()) end
  return true, nil, rgid[0], egid[0], sgid[0]
end
function S.setresuid(ruid, euid, suid) return retbool(C.setresuid(ruid, euid, suid)) end
function S.setresgid(rgid, egid, sgid) return retbool(C.setresgid(rgid, egid, sgid)) end

function S.vhangup() return retbool(C.vhangup()) end

function S.swapon(path, swapflags) return retbool(C.swapon(path, c.SWAP_FLAG[swapflags])) end
function S.swapoff(path) return retbool(C.swapoff(path)) end

-- capabilities. Somewhat complex kernel interface due to versioning, Posix requiring malloc in API.
-- only support version 3, should be ok for recent kernels, or pass your own hdr, data in
-- to detect capability API version, pass in hdr with empty version, version will be set
function S.capget(hdr, data) -- normally just leave as nil for get, can pass pid in
  hdr = istype(t.user_cap_header, hdr) or t.user_cap_header(c.LINUX_CAPABILITY_VERSION[3], hdr or 0)
  if not data and hdr.version ~= 0 then data = t.user_cap_data2() end
  local ret, err = C.capget(hdr, data)
  if ret == -1 then return nil, t.error(err or errno()) end
  if not data then return hdr end
  return t.capabilities(hdr, data)
end

function S.capset(hdr, data)
  if ffi.istype(t.capabilities, hdr) then hdr, data = hdr:hdrdata() end
  return retbool(C.capset(hdr, data))
end

function S.getcpu(cpu, node)
  cpu = cpu or t.uint1()
  node = node or t.uint1()
  local ret, err = C.getcpu(cpu, node)
  if ret == -1 then return nil, t.error(err or errno()) end
  return {cpu = cpu[0], node = node[0]}
end

function S.sched_getscheduler(pid) return retnum(C.sched_getscheduler(pid or 0)) end
function S.sched_setscheduler(pid, policy, param)
  param = mktype(t.sched_param, param or 0)
  return retbool(C.sched_setscheduler(pid or 0, c.SCHED[policy], param))
end
function S.sched_yield() return retbool(C.sched_yield()) end

function S.sched_getaffinity(pid, mask, len) -- note len last as rarely used. All parameters optional
  mask = mktype(t.cpu_set, mask)
  local ret, err = C.sched_getaffinity(pid or 0, len or s.cpu_set, mask)
  if ret == -1 then return nil, t.error(err or errno()) end
  return mask
end

function S.sched_setaffinity(pid, mask, len) -- note len last as rarely used
  return retbool(C.sched_setaffinity(pid or 0, len or s.cpu_set, mktype(t.cpu_set, mask)))
end

function S.sched_get_priority_max(policy) return retnum(C.sched_get_priority_max(c.SCHED[policy])) end
function S.sched_get_priority_min(policy) return retnum(C.sched_get_priority_min(c.SCHED[policy])) end

function S.sched_setparam(pid, param)
  return retbool(C.sched_setparam(pid or 0, mktype(t.sched_param, param or 0)))
end
function S.sched_getparam(pid, param)
  param = mktype(t.sched_param, param or 0)
  local ret, err = C.sched_getparam(pid or 0, param)
  if ret == -1 then return nil, t.error(err or errno()) end
  return param.sched_priority -- only one useful parameter
end

function S.sched_rr_get_interval(pid, ts)
  ts = mktype(t.timespec, ts)
  local ret, err = C.sched_rr_get_interval(pid or 0, ts)
  if ret == -1 then return nil, t.error(err or errno()) end
  return ts
end

-- POSIX message queues. Note there is no mq_close as it is just close in Linux
function S.mq_open(name, flags, mode, attr)
  local ret, err = C.mq_open(name, c.O[flags], c.MODE[mode], mktype(t.mq_attr, attr))
  if ret == -1 then return nil, t.error(err or errno()) end
  return t.mqd(ret)
end

function S.mq_unlink(name)
  return retbool(C.mq_unlink(name))
end

function S.mq_getsetattr(mqd, new, old) -- provided for completeness, but use getattr, setattr which are methods
  return retbool(C.mq_getsetattr(getfd(mqd), new, old))
end

function S.mq_timedsend(mqd, msg_ptr, msg_len, msg_prio, abs_timeout)
  if abs_timeout then abs_timeout = mktype(t.timespec, abs_timeout) end
  return retbool(C.mq_timedsend(getfd(mqd), msg_ptr, msg_len or #msg_ptr, msg_prio or 0, abs_timeout))
end

-- like read, return string if buffer not provided. Length required. TODO should we return prio?
function S.mq_timedreceive(mqd, msg_ptr, msg_len, msg_prio, abs_timeout)
  if abs_timeout then abs_timeout = mktype(t.timespec, abs_timeout) end
  if msg_ptr then return retbool(C.mq_timedreceive(getfd(mqd), msg_ptr, msg_len or #msg_ptr, msg_prio, abs_timeout)) end
  msg_ptr = t.buffer(msg_len)
  local ret, err = C.mq_timedreceive(getfd(mqd), msg_ptr, msg_len or #msg_ptr, msg_prio, abs_timeout)
  if ret == -1 then return nil, t.error(err or errno()) end
  return ffi.string(msg_ptr,ret)
end

-- pty functions where not in common code TODO move to linux/libc?
function S.grantpt(fd) return true end -- Linux does not need to do anything here (Musl does not)
function S.unlockpt(fd) return S.ioctl(fd, "TIOCSPTLCK", 0) end
function S.ptsname(fd)
  local pts, err = S.ioctl(fd, "TIOCGPTN")
  if not pts then return nil, err end
  return "/dev/pts/" .. tostring(pts)
end
function S.tcgetattr(fd) return S.ioctl(fd, "TCGETS") end
local tcsets = {
  [c.TCSA.NOW]   = "TCSETS",
  [c.TCSA.DRAIN] = "TCSETSW",
  [c.TCSA.FLUSH] = "TCSETSF",
}
function S.tcsetattr(fd, optional_actions, tio)
  local inc = c.TCSA[optional_actions]
  return S.ioctl(fd, tcsets[inc], tio)
end
function S.tcsendbreak(fd, duration)
  return S.ioctl(fd, "TCSBRK", pt.void(0)) -- Linux ignores duration
end
function S.tcdrain(fd)
  return S.ioctl(fd, "TCSBRK", pt.void(1)) -- note use of literal 1 cast to pointer
end
function S.tcflush(fd, queue_selector)
  return S.ioctl(fd, "TCFLSH", pt.void(c.TCFLUSH[queue_selector]))
end
function S.tcflow(fd, action)
  return S.ioctl(fd, "TCXONC", pt.void(c.TCFLOW[action]))
end

-- compat code for stuff that is not actually a syscall under Linux

-- old rlimit functions in Linux are 32 bit only so now defined using prlimit
function S.getrlimit(resource)
  return S.prlimit(0, resource)
end

function S.setrlimit(resource, rlim)
  local ret, err = S.prlimit(0, resource, rlim)
  if not ret then return nil, err end
  return true
end

function S.gethostname()
  local u, err = S.uname()
  if not u then return nil, err end
  return u.nodename
end

function S.getdomainname()
  local u, err = S.uname()
  if not u then return nil, err end
  return u.domainname
end

function S.killpg(pgrp, sig) return S.kill(-pgrp, sig) end

-- helper function to read inotify structs as table from inotify fd, TODO could be in util
function S.inotify_read(fd, buffer, len)
  len = len or 1024
  buffer = buffer or t.buffer(len)
  local ret, err = S.read(fd, buffer, len)
  if not ret then return nil, err end
  return t.inotify_events(buffer, ret)
end

-- in Linux mkfifo is not a syscall, emulate
function S.mkfifo(path, mode) return S.mknod(path, bit.bor(c.MODE[mode], c.S_I.FIFO)) end
function S.mkfifoat(fd, path, mode) return S.mknodat(fd, path, bit.bor(c.MODE[mode], c.S_I.FIFO), 0) end

-- in Linux shm_open and shm_unlink are not syscalls
local shm = "/dev/shm"

function S.shm_open(pathname, flags, mode)
  if pathname:sub(1, 1) ~= "/" then pathname = "/" .. pathname end
  pathname = shm .. pathname
  return S.open(pathname, c.O(flags, "nofollow", "cloexec", "nonblock"), mode)
end

function S.shm_unlink(pathname)
  if pathname:sub(1, 1) ~= "/" then pathname = "/" .. pathname end
  pathname = shm .. pathname
  return S.unlink(pathname)
end

-- TODO setpgrp and similar - see the man page

-- in Linux pathconf can just return constants

-- TODO these could go into constants, although maybe better to get from here, and some are slightly bogus eg PAGE_SIZE
local PAGE_SIZE = 4096
local NAME_MAX = 255
local PATH_MAX = 4096 -- TODO this is in constants, inconsistently
local PIPE_BUF = 4096
local FILESIZEBITS = 64
local SYMLINK_MAX = 255
local _POSIX_LINK_MAX = 8
local _POSIX_MAX_CANON = 255
local _POSIX_MAX_INPUT = 255

local pathconf_values = {
  [c.PC.LINK_MAX] = _POSIX_LINK_MAX,
  [c.PC.MAX_CANON] = _POSIX_MAX_CANON,
  [c.PC.MAX_INPUT] = _POSIX_MAX_INPUT,
  [c.PC.NAME_MAX] = NAME_MAX,
  [c.PC.PATH_MAX] = PATH_MAX,
  [c.PC.PIPE_BUF] = PIPE_BUF,
  [c.PC.CHOWN_RESTRICTED] = 1,
  [c.PC.NO_TRUNC] = 1,
  [c.PC.VDISABLE] = 0,
  [c.PC.SYNC_IO] = 1,
  [c.PC.ASYNC_IO] = -1,
  [c.PC.PRIO_IO] = -1,
  [c.PC.SOCK_MAXBUF] = -1,
  [c.PC.FILESIZEBITS] = FILESIZEBITS,
  [c.PC.REC_INCR_XFER_SIZE] = PAGE_SIZE,
  [c.PC.REC_MAX_XFER_SIZE] = PAGE_SIZE,
  [c.PC.REC_MIN_XFER_SIZE] = PAGE_SIZE,
  [c.PC.REC_XFER_ALIGN] = PAGE_SIZE,
  [c.PC.ALLOC_SIZE_MIN] = PAGE_SIZE,
  [c.PC.SYMLINK_MAX] = SYMLINK_MAX,
  [c.PC["2_SYMLINKS"]] = 1,
}

function S.pathconf(_, name) return pathconf_values[c.PC[name]] end
function S.fpathconf(_, name) return pathconf_values[c.PC[name]] end

-- setegid and set euid are not syscalls
function S.seteuid(euid) return S.setresuid(-1, euid, -1) end
function S.setegid(egid) return S.setresgid(-1, egid, -1) end

return S

end

