require "lib_c"

module Bootstrap
  module Syscalls
    # Syscall references:
    # - unshare(2): https://man7.org/linux/man-pages/man2/unshare.2.html
    # - mount(2): https://man7.org/linux/man-pages/man2/mount.2.html
    # - umount2(2): https://man7.org/linux/man-pages/man2/umount2.2.html
    # - pivot_root(2): https://man7.org/linux/man-pages/man2/pivot_root.2.html
    # - chdir(2): https://man7.org/linux/man-pages/man2/chdir.2.html
    # - chroot(2): https://man7.org/linux/man-pages/man2/chroot.2.html
    # - sethostname(2): https://man7.org/linux/man-pages/man2/sethostname.2.html
    lib LibC
      fun unshare(flags : Int32) : Int32
      fun mount(source : ::LibC::Char*, target : ::LibC::Char*, filesystemtype : ::LibC::Char*, mountflags : ::LibC::ULong, data : Void*) : Int32
      fun umount2(target : ::LibC::Char*, flags : Int32) : Int32
      fun pivot_root(new_root : ::LibC::Char*, put_old : ::LibC::Char*) : Int32
      fun chdir(path : ::LibC::Char*) : Int32
      fun chroot(path : ::LibC::Char*) : Int32
      fun sethostname(name : ::LibC::Char*, len : ::LibC::SizeT) : Int32
      fun getuid : ::LibC::UidT
      fun getgid : ::LibC::GidT
    end

    # clone flags from linux/sched.h (see unshare(2)).
    CLONE_NEWUSER = 0x10000000 # https://man7.org/linux/man-pages/man2/unshare.2.html
    CLONE_NEWNS   = 0x00020000 # https://man7.org/linux/man-pages/man2/unshare.2.html
    CLONE_NEWUTS  = 0x04000000 # https://man7.org/linux/man-pages/man2/unshare.2.html

    # mount flags from linux/fs.h (see mount(2)).
    MS_RDONLY  = ::LibC::ULong.new(0x1)      # https://man7.org/linux/man-pages/man2/mount.2.html
    MS_NOSUID  = ::LibC::ULong.new(0x2)      # https://man7.org/linux/man-pages/man2/mount.2.html
    MS_NODEV   = ::LibC::ULong.new(0x4)      # https://man7.org/linux/man-pages/man2/mount.2.html
    MS_NOEXEC  = ::LibC::ULong.new(0x8)      # https://man7.org/linux/man-pages/man2/mount.2.html
    MS_BIND    = ::LibC::ULong.new(0x1000)   # https://man7.org/linux/man-pages/man2/mount.2.html
    MS_REC     = ::LibC::ULong.new(0x4000)   # https://man7.org/linux/man-pages/man2/mount.2.html
    MS_PRIVATE = ::LibC::ULong.new(0x40000)  # https://man7.org/linux/man-pages/man2/mount.2.html
    MS_SLAVE   = ::LibC::ULong.new(0x80000)  # https://man7.org/linux/man-pages/man2/mount.2.html
    MS_SHARED  = ::LibC::ULong.new(0x100000) # https://man7.org/linux/man-pages/man2/mount.2.html

    # umount2 flags from linux/fs.h (see umount2(2)).
    MNT_DETACH = 0x2 # https://man7.org/linux/man-pages/man2/umount2.2.html

    # /proc/self/* mapping ABI described in user_namespaces(7).
    ALLOWED_PROC_SELF_MAPS = {"uid_map", "gid_map", "setgroups"} # https://man7.org/linux/man-pages/man7/user_namespaces.7.html

    private def self.raise_errno(op : String)
      raise RuntimeError.from_os_error(op, Errno.value)
    end

    def self.unshare(flags : Int32) : Int32
      result = LibC.unshare(flags)
      raise_errno("unshare") unless result == 0
      result
    end

    def self.mount(source : String?, target : String, filesystemtype : String?, mountflags : ::LibC::ULong, data : String? = nil) : Int32
      source_ptr = source ? source.to_unsafe : Pointer(::LibC::Char).null
      fstype_ptr = filesystemtype ? filesystemtype.to_unsafe : Pointer(::LibC::Char).null
      data_ptr = data ? data.to_unsafe.as(Void*) : Pointer(Void).null
      result = LibC.mount(source_ptr, target.to_unsafe, fstype_ptr, mountflags, data_ptr)
      raise_errno("mount") unless result == 0
      result
    end

    def self.umount2(target : String, flags : Int32) : Int32
      result = LibC.umount2(target.to_unsafe, flags)
      raise_errno("umount2") unless result == 0
      result
    end

    def self.pivot_root(new_root : String, put_old : String) : Int32
      result = LibC.pivot_root(new_root.to_unsafe, put_old.to_unsafe)
      raise_errno("pivot_root") unless result == 0
      result
    end

    def self.chdir(path : String) : Int32
      result = LibC.chdir(path.to_unsafe)
      raise_errno("chdir") unless result == 0
      result
    end

    def self.chroot(path : String) : Int32
      result = LibC.chroot(path.to_unsafe)
      raise_errno("chroot") unless result == 0
      result
    end

    def self.sethostname(name : String) : Int32
      result = LibC.sethostname(name.to_unsafe, name.bytesize)
      raise_errno("sethostname") unless result == 0
      result
    end

    def self.uid : Int32
      LibC.getuid.to_i
    end

    def self.gid : Int32
      LibC.getgid.to_i
    end

    # /proc/self path is the ABI for namespace mappings (user_namespaces(7)).
    PROC_SELF_ROOT = "/proc/self" # https://man7.org/linux/man-pages/man7/user_namespaces.7.html

    def self.write_proc_self_map(entry : String, content : String, root : String = PROC_SELF_ROOT)
      unless ALLOWED_PROC_SELF_MAPS.includes?(entry)
        raise ArgumentError.new("Unsupported proc entry #{entry}")
      end

      if content.includes?('\0')
        raise ArgumentError.new("Mapping content cannot include null bytes")
      end

      payload = content.ends_with?("\n") ? content : "#{content}\n"
      File.open(File.join(root, entry), "w") do |file|
        file.sync = true
        file.print(payload)
      end
    end
  end
end
