---
applyTo: "**/*.{pas,pp}"
description: "Pascal and FreePascal conventions for EchoScript source files, including compiler settings, naming, formatting, and file handling rules."
---

# Pascal Files (.pas, .pp)

Use FreePascal compilation binary `c:\projects\fpc-trunk\compiler\utils\fpc.exe`
Use environment variable `FPC_CFG=c:\projects\MindWave\pas\fpc-build\fpc-trunk-x64.cfg` for compilation

Target platform x64

# Pascal Code Conventions

Don't change line ending and don't change code page of files.

## Naming Conventions

### Local Variables
- All local variables must start with a lowercase letter
- Use camelCase for multi-word variable names
- Sort local variables declarations by string length (shortest first)

**Examples:**
```pascal
var
    len: Integer;
    offset: Integer;
    plainData: TBytes;
    encryptedData: TBytes;
    userNameBytes, eMailBytes, hwIDBytes: TBytes;
```

**Bad (unsorted):**
```pascal
var
    encryptedData: TBytes;
    plainData: TBytes;
    offset: Integer;
    userNameBytes, eMailBytes, hwIDBytes: TBytes;
    len: Integer;
```

### Class Fields (Private)
- Private fields should use the F-prefix notation
- Use camelCase for the rest of the name
- First letter after F should be lowercased
- Fields should be indented with 4 spaces
- Colon should be aligned at position 33 (column 33)

**Example:**
```pascal
private
    FuserName               : string;
    FexpirationDate         : TDateTime;
    FuserData               : TBytes;
```

### Properties
- Properties should follow PascalCase (first letter uppercase)
- Provide read/write access via getter/setter methods
- First letter of property name should be UpperCase

**Example:**
```pascal
public
    property UserName: string read FuserName write FUserName;
    property ExpirationDate: TDateTime read FexpirationDate write FExpirationDate;
```

### Instance Methods
- All instance method names (except `Create`, `Destroy`, and class methods) should start with a lowercase letter
- Use camelCase for multi-word method names
- In method declarations, the method name should start at column 17 (4 spaces indent + "function"/"procedure" + spaces)

**Examples:**
```pascal
    function    dateTimeToBytes(const aDateTime: TDateTime): TBytes;
    function    generateLicense(const aInfo: TLicenseInfo): string;
    function    parseLicense(const aLicense: string; out aInfo: TLicenseInfo): Boolean;
    procedure   validateLicense(const aLicense: string);
```

### Parameters
- All parameters must use the 'a' prefix
- Use `const` for read-only parameters

**Examples:**
```pascal
procedure foo(const aUserName: string);
function boo(aDigit: integer);
function parseLicense(const aLicense: string; out aInfo: TLicenseInfo): Boolean;
```