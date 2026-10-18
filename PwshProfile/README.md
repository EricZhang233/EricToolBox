# PwshProfile

PowerShell 7 profile. `Microsoft.PowerShell_profile.ps1` is the exact file `pwsh` loads from `$PROFILE.CurrentUserCurrentHost` — no build step, no module manifest, nothing to compile.

## Contents

Three sections, in this order:

| Section | Contents |
| --- | --- |
| Shell helpers | `$ProjectRoot` and the `cdp` function |
| .NET shortcuts | `.n`, `.nc`, `.nr`, `.nbr`, `.nbd`, `.nrr`, `.nrd` |
| CMake shortcuts | `.c`, `.cc`, `.cbd`, `.cbr` |

`cdp` depends on `$ProjectRoot`. Nothing else in the file depends on anything else.

## Requirements

- PowerShell 7 (`pwsh`), tested on 7.6.
- A directory holding your projects. One is configured in the file; change it with `cdp -setdir <path>`. See [Adapting to your environment](#adapting-to-your-environment).

## Install

### No existing profile

```powershell
Copy-Item .\Microsoft.PowerShell_profile.ps1 $PROFILE.CurrentUserCurrentHost
```

On PowerShell 7 that path is `C:\Users\<you>\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`.

> `Documents\PowerShell`, not `Documents\WindowsPowerShell`. The latter belongs to Windows PowerShell 5.1 and is never read by `pwsh`.

### Existing profile: append, do not overwrite

Copying the file over an existing profile removes every other function, alias, and prompt customization in it.

Append instead:

```powershell
# backup first
Copy-Item $PROFILE.CurrentUserCurrentHost "$PROFILE.CurrentUserCurrentHost.bak"

# append, separated by a blank line
Add-Content $PROFILE.CurrentUserCurrentHost "`n# --- PwshProfile ---"
Add-Content $PROFILE.CurrentUserCurrentHost (Get-Content .\Microsoft.PowerShell_profile.ps1 -Raw)
```

To install only the jumper, append the `Shell helpers` section instead: `$ProjectRoot` plus the `cdp` function, from `# --------- Shell helpers ...` to the closing brace of `cdp`.

If `cdp` or `$ProjectRoot` is already defined, the appended definition takes effect, because it is defined later.

Reload without restarting the shell:

```powershell
. $PROFILE
```

Verify:

```powershell
$ProjectRoot   # -> your project root
cdp            # -> changes to it
```

## `cdp`

| Command | Effect |
| --- | --- |
| `cdp` | Change to `$ProjectRoot` |
| `cdp -list` / `cdp -ls` | List project names with their full paths |
| `cdp <TAB>` | List project directories under the root |
| `cdp web<TAB>` | Complete by prefix (`webapp`, `webapi`, ...) |
| `cdp webapp\src<TAB>` | Complete inside a project |
| `cdp webapp tests` | Multiple arguments are joined with `\` |
| `cdp C:\Windows` | Absolute paths are used as given |
| `cdp ..` | Relative paths resolve against the root |
| `cdp -setdir D:\Code` | Change the root and persist it |

```powershell
PS> cdp -list

Project  Path
-------  ----
webapi   <root>\webapi
webapp   <root>\webapp
```

`cdp -list` emits plain objects rather than formatted text, so it composes: `cdp -list | Sort-Object Path`, `cdp -list | Export-Csv projects.csv`.

Directory names are read from the filesystem on every call; no list is cached. Errors are reported as a single line, and the current location is left unchanged:

```
cdp: directory not found: <root>\nope
```

An unrecognised option is rejected instead of being treated as a directory name:

```
cdp: unknown option '-lsd'. valid: cdp -list, cdp -setdir <path> (did you mean -list?)
```

## Configuration

```powershell
$global:ProjectRoot = '<your root>'  # change with: cdp -setdir <path>
```

- Persistent — `cdp -setdir D:\Code` rewrites that line in the profile (retaining any trailing comment), updates the current session, and changes directory.
- Session only — `$ProjectRoot = 'D:\Code'` at the prompt; inside a function or script use `$global:ProjectRoot`.

The value is read on every `cdp` call, so completion and navigation reflect a change immediately. Reloading the profile resets it to the value written in the file.

## Shortcuts

Both groups forward extra arguments, so `.nbr -v n` works.

| Shortcut | Runs |
| --- | --- |
| `.n` | `dotnet` |
| `.nc` | `dotnet clean` |
| `.nr` | `dotnet restore` |
| `.nbr` / `.nbd` | `dotnet build -c Release` / `dotnet build -c Debug` |
| `.nrr` / `.nrd` | `dotnet run -c Release` / `dotnet run -c Debug` |
| `.c` | `cmake` |
| `.cc` | configure `vs18-x64`, then `--build --preset debug --target clean` |
| `.cbd` / `.cbr` | configure `vs18-x64`, then `--build --preset debug` / `release` |

The `.c*` group requires a configure preset named `vs18-x64` and build presets named `debug` and `release`.

## Adapting to your environment

- `$ProjectRoot` — set it to your project root with `cdp -setdir <path>`.
- `.c*` preset names — `vs18-x64`, `debug`, `release`. Replace with the preset names used by your projects, or call `.c` with explicit arguments.
- No other absolute paths are referenced.

## Implementation notes

- `cdp` is a plain function. Its first positional parameter carries an `ArgumentCompleter` script block that lists directories under `$global:ProjectRoot`, filters by the typed prefix, and splits on the last `\` or `/` so subdirectories complete too.
- `-setdir` matches only a column-0 `$ProjectRoot` assignment, so an indented assignment inside a function body is never a candidate. It replaces the value and retains any trailing comment; if the line is missing entirely, it is recreated below the first `# --------- ... ---------` section header.
- Parameter sets are not used. With two parameter sets both owning position 0, PowerShell's completion engine cannot determine which applies and drops the completer, falling back to file completion. One named parameter plus one positional parameter behaves correctly.
- The file is pure ASCII, no BOM, LF line endings.
- `.n` and `.c` are functions, not aliases: `Get-Command .n` finds them, `Get-Alias .n` does not.

## Uninstall

Remove the appended block, or delete the file if it was installed as the whole profile. Open a new shell.

## License

GPL-3.0, matching the parent [EricToolBox](../README.md) repository.
