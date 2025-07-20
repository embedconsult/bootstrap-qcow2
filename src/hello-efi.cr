require "efi"

def efi_main(handle : LibEfi::Handle, st : LibEfi::SystemTable) : LibEfi::Status
  efi = Efi.new(handle, st)
  efi.out "Hello Crystal World"
  LibEfi::Status::Success
end
