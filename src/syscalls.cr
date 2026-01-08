require "lib_c"

module Bootstrap
  module Syscalls
    # Thin libc syscall bindings with small helpers for namespace and mount setup.
    # Kernel documentation: https://docs.kernel.org/userspace-api/namespaces.html
    lib LibC
      fun unshare(flags : Int32) : Int32
      fun mount(source : ::LibC::Char*, target : ::LibC::Char*, filesystemtype : ::LibC::Char*, mountflags : ::LibC::ULong, data : Void*) : Int32
      fun umount2(target : ::LibC::Char*, flags : Int32) : Int32
      fun pivot_root(new_root : ::LibC::Char*, put_old : ::LibC::Char*) : Int32
      fun chdir(path : ::LibC::Char*) : Int32
      fun chroot(path : ::LibC::Char*) : Int32
      fun sethostname(name : ::LibC::Char*, len : ::LibC::SizeT) : Int32
    end

    # Clone/unshare flags (see include/uapi/linux/sched.h).
    CLONE_NEWUSER = 0x10000000
    CLONE_NEWNS   = 0x00020000

    # Mount flags (see include/uapi/linux/fs.h and shared subtree docs).
    MS_RDONLY  = ::LibC::ULong.new(0x1)
    MS_NOSUID  = ::LibC::ULong.new(0x2)
    MS_NODEV   = ::LibC::ULong.new(0x4)
    MS_NOEXEC  = ::LibC::ULong.new(0x8)
    MS_BIND    = ::LibC::ULong.new(0x1000)
    MS_REC     = ::LibC::ULong.new(0x4000)
    MS_PRIVATE = ::LibC::ULong.new(0x40000)
    MS_SLAVE   = ::LibC::ULong.new(0x80000)
    MS_SHARED  = ::LibC::ULong.new(0x100000)

    # Unmount flags (see include/uapi/linux/mount.h).
    MNT_DETACH = 0x2

    ALLOWED_PROC_SELF_MAPS = {"uid_map", "gid_map", "setgroups"}

    private def self.raise_errno(context : String) : NoReturn
      raise RuntimeError.from_errno(context)
    end

    # Unshare namespaces via libc and raise on failure.
    def self.unshare(flags : Int32) : Int32
      result = LibC.unshare(flags)
      raise_errno("unshare") unless result == 0
      result
    end

    # Mount a filesystem and raise on failure.
    def self.mount(source : String?, target : String, filesystemtype : String?, mountflags : ::LibC::ULong, data : String? = nil) : Int32
      source_ptr = source ? source.to_unsafe : Pointer(::LibC::Char).null
      fstype_ptr = filesystemtype ? filesystemtype.to_unsafe : Pointer(::LibC::Char).null
      data_ptr = data ? data.to_unsafe.as(Void*) : Pointer(Void).null
      result = LibC.mount(source_ptr, target.to_unsafe, fstype_ptr, mountflags, data_ptr)
      raise_errno("mount") unless result == 0
      result
    end

    # Unmount and raise on failure.
    def self.umount2(target : String, flags : Int32) : Int32
      result = LibC.umount2(target.to_unsafe, flags)
      raise_errno("umount2") unless result == 0
      result
    end

    # Pivot root and raise on failure.
    def self.pivot_root(new_root : String, put_old : String) : Int32
      result = LibC.pivot_root(new_root.to_unsafe, put_old.to_unsafe)
      raise_errno("pivot_root") unless result == 0
      result
    end

    # Change working directory and raise on failure.
    def self.chdir(path : String) : Int32
      result = LibC.chdir(path.to_unsafe)
      raise_errno("chdir") unless result == 0
      result
    end

    # Change root and raise on failure.
    def self.chroot(path : String) : Int32
      result = LibC.chroot(path.to_unsafe)
      raise_errno("chroot") unless result == 0
      result
    end

    # Set host name and raise on failure.
    def self.sethostname(name : String) : Int32
      result = LibC.sethostname(name.to_unsafe, name.bytesize)
      raise_errno("sethostname") unless result == 0
      result
    end

    # Procfs namespace ABI docs:
    # https://docs.kernel.org/filesystems/proc.html#proc-pid-uid-map
    # https://docs.kernel.org/filesystems/proc.html#proc-pid-gid-map
    # https://docs.kernel.org/filesystems/proc.html#proc-pid-setgroups
    PROC_SELF_ROOT = "/proc/self"

    # Write validated mapping content to /proc/self/{uid_map,gid_map,setgroups}.
    def self.write_proc_self_map(entry : String, content : String, root : String = PROC_SELF_ROOT)
      unless ALLOWED_PROC_SELF_MAPS.includes?(entry)
        raise ArgumentError.new("Unsupported proc entry #{entry}")
      end

      if content.includes?('\0')
        raise ArgumentError.new("Mapping content cannot include null bytes")
      end

      payload = content.ends_with?("\n") ? content : "#{content}\n"
      File.open("#{root}/#{entry}", "w") do |file|
        file.sync = true
        file.print(payload)
      end
    end
  end
end
