#![no_main]
#![no_std]

use log::info;
use uefi::prelude::*;

#[entry]
fn main() -> Status {
    uefi::helpers::init().unwrap();
    info!("Hello EFI world from Rust!");
    boot::stall(10_000_000);
    Status::SUCCESS
}

