lib LibEfi
  struct Guid
    # Low field of the timestamp
    a: UInt32
    # Middle field of the timestamp
    b: UInt16
    # High field of the timestamp
    c: UInt16
    # Contains:
    #  - The high field of the clock sequence multiplexed with the variant.
    #  - The low field of the clock sequence.
    #  - Spatially unique node identifier.
    d: UInt8[8]
  end

  # https://uefi.org/specs/UEFI/2.10/Apx_D_Status_Codes.html?highlight=efi_status#status-codes
  enum Status : UInt64
    Success = 0
    WarnUnknownGlyph
    WarnDeleteFailure
    WarnWriteFailure
    WarnBufferTooSmall
    WarnStaleData
    WarnFileSystem
    WarnResetRequired

    LoadError = 0x8000_0000_0000_0001
    InvalidParameter
    Unsupported
    BadBufferSize
    BufferTooSmall
    NotReady
    DeviceError
    WriteProtected
    OutOfResources
    VolumeCorrupted
    VolumeFull
    NoMedia
    MediaChanged
    NotFound
    AccessDenied
    NoResponse
    NoMapping
    Timeout
    NotStarted
    AlreadyStarted
    Aborted
    IcmpError
    TftpError
    ProtocolError
    IncompatibleVersion
    SecurityViolation
    CrcError
    EndOfMedia

    EndOfFile = 0x8000_0000_0000_001F
    InvalidLanguage
    CompromisedData
    IpAddressConflict
    HttpError
  end

  # https://uefi.org/specs/UEFI/2.10/Apx_B_Console.html#efi-scan-codes-for-efi-simple-text-input-protocol
  enum ScanCode : UInt16
    Null = 0
    Up
    Down
    Right
    Left
    Home
    End
    Insert
    Delete
    PageUp
    PageDown
    Function1
    Function2
    Function3
    Function4
    Function5
    Function6
    Function7
    Function8
    Function9
    Function10
    Function11
    Function12
    Escape

    Pause = 0x48

    Function13 = 0x68
    Function14
    Function15
    Function16
    Function17
    Function18
    Function19
    Function20
    Function21
    Function22
    Function23
    Function24

    Mute = 0x7F

    VolumeUp = 0x80
    VolumeDown

    BrightnessUp = 0x100
    BrightnessDown
    Suspend
    Hibernate
    ToggleDisplay
    Recovery
    Eject
  end

  # https://uefi.org/specs/UEFI/2.10/12_Protocols_Console_Support.html#efi-simple-text-input-protocol-readkeystroke
  struct InputKey
    scan_code: ScanCode
    unicode_char: UInt16
  end

  # https://uefi.org/specs/UEFI/2.10/12_Protocols_Console_Support.html#efi-simple-text-input-protocol
  struct Input
    reset: (Input*, Bool) -> Status
    read_key_stroke: (Input*, InputKey*) -> Status
  end

  # https://uefi.org/specs/UEFI/2.10/12_Protocols_Console_Support.html#efi-simple-text-output-protocol
  struct Output
    reset: (Output*, Bool) -> Status
  end

  # https://uefi.org/specs/UEFI/2.10/04_EFI_System_Table.html#id4
  struct Header
    signature: UInt64
    revision: UInt32
    size: UInt32
    crc: UInt32
    _reserved: UInt32
  end

  # https://uefi.org/specs/UEFI/2.10/04_EFI_System_Table.html#efi-configuration-table
  struct ConfigTableEntry
    guid: Guid
    vendor_table: Void*
  end

  alias Handle = Void*

  # https://uefi.org/specs/UEFI/2.10/04_EFI_System_Table.html#efi-runtime-services
  struct RuntimeServices
    header: Header
    _pad: UInt64[10]
    reset: (UInt32, Status, UInt64, UInt8*) -> 
  end

  # https://uefi.org/specs/UEFI/2.10/04_EFI_System_Table.html#efi-boot-services
  struct BootServices
    header: Header
  end

  # https://uefi.org/specs/UEFI/2.10/04_EFI_System_Table.html#id6
  struct SystemTable
    header: Header
    fw_vendor: UInt16*
    fw_revision: UInt32
    stdin_handle: Handle
    stdin: Input*
    stdout_handle: Handle
    stdout: Output*
    stderr_handle: Handle
    stderr: Output*
    runtime: RuntimeServices*
    boot: BootServices*
    # TODO: confirm pointer size is always 64 bits
    nr_cfg: UInt64
    cfg_table: StaticArray(ConfigTableEntry, 30)
  end
end

class Efi
  def initialize(@handle : LibEfi::Handle, @system_table : LibEfi::SystemTable)
  end

  def out(message : String)
  end
end

fun __chkstk
end
