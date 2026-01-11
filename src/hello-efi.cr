require "../ignore/efi"

fun efi_main(handle : LibEfi::Handle, st : LibEfi::SystemTable) : LibEfi::Status
  efi = Efi.new(handle, st)
  efi.out "Hello Crystal"
  LibEfi::Status::Success
end
