# EthnoCount Desktop Build Instructions

This document provides instructions for building and packaging the EthnoCount application for Windows Desktop.

## Prerequisites

Before building for Windows, ensure you have the following installed:
1. **Flutter SDK**: Ensure you are on a stable channel (e.g., ^3.10.7) and have Windows desktop support enabled.
   ```bash
   flutter config --enable-windows-desktop
   ```
2. **Visual Studio**: Install Visual Studio 2022 Setup with the "Desktop development with C++" workload. This is required by Flutter to compile Windows applications.

## Building the Executable

To build the release version of the Windows application:

1. Open a terminal in the project root directory.
2. Run the build command:
   ```bash
   flutter build windows --release
   ```

## Locating the Output

After a successful build, the compiled `.exe` files and their required DLLs and assets can be found in the following directory:

`build/windows/runner/Release/`

The main executable will be named `ethnocount.exe`.

## Packaging for Distribution

You cannot simply copy the `ethnocount.exe` file. The application requires the entire contents of the `Release` folder to run correctly.

**To share the application:**
1. Zip the entire `build/windows/runner/Release/` folder.
2. Distribute the zip file.
3. Instruct users to extract the zip file and run `ethnocount.exe`.

**To create an installer (Optional but recommended):**
You can use tools like **Inno Setup** to create a standard Windows installer (`.exe` or `.msi`) that installs the application into `C:\Program Files\EthnoCount` and creates a desktop shortcut.

### Important Build Notes
* **File Permissions**: The app will request standard permissions. If your app writes data to paths other than `ApplicationDocuments` (via `path_provider`), ensure users run it with appropriate permissions.
* **Architecture**: The build defaults to x64.
* **Dependencies**: Any desktop-specific plugins (like `file_selector`, `file_saver`, `path_provider`) must be tested fully on a Windows machine to ensure compatibility.
