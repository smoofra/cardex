# cardex

iOS app for cataloguing books by scanning their ISBN barcode and RFID tag, saving the pair to iCloud.

## What it does

1. **Scan ISBN** — uses the camera to read an EAN-13 barcode from a book's cover
2. **Scan RFID** — connects to a TSL 1128 Bluetooth UHF RFID reader and scans the tag attached to the book
3. **Save** — appends the ISBN/EPC pair as a row in `cardex.csv` in iCloud Drive

## Requirements

- iOS 26+
- [TSL 1128](https://www.tsl.com/products/1128/) Bluetooth UHF RFID reader
- iCloud Drive enabled

## Setup

### Dependencies

The TSL ASCII 2.0 SDK (`TSLAsciiCommands.xcframework`) is included as a local reference from `../TSL UHF ASCII 2.0 SDK v1.6.1/`. Clone or copy that SDK alongside this repo before opening the project.

### Capabilities

The following capabilities must be enabled on the App ID in the Apple Developer portal:

- **iCloud** (Documents)
- **Bluetooth** — the app uses `CBCentralManager` to trigger the system Bluetooth permission prompt before presenting the ExternalAccessory picker

### First run

On first launch, iOS will ask for Bluetooth and Camera permissions. After granting Bluetooth access, tapping **Connect** in the RFID view will show the system Bluetooth accessory picker to pair the TSL 1128. Subsequent launches connect automatically if the reader is already paired.

## Output

Scans are appended to `cardex.csv` in the app's iCloud Documents container (`iCloud.org.elder-gods.cardex`), visible in the Files app under iCloud Drive → cardex.

```
"isbn","epc"
"9780743273565","E20034120119E5400F6B5B6B"
```
