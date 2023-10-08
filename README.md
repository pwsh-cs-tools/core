# PowerShell C# Tools - Core
PowerShell is an amazing language, but doesn't get all the love that C# does by the Microsoft and the C# community. This repository aims to restore and implement features available in C# that are not natively/directly available in PowerShell.

## Features
- Adds ability to import NuGet/Nupkg packages downloaded by PackageManagement
  - `Import-Package`
- (WIP) Adds significantly improved asynchronous code execution by providing runspace constructors that return a dispatcher
  - `New-DispatcherSpace`
- (WIP) For PowerShell Core on Windows, adds WinRT API back into PowerShell Core on Windows
  - This will add UWP APIs back into PowerShell Core on Windows
  - Will use this workaround: https://github.com/PowerShell/PowerShell/issues/13042#issuecomment-653357546
