# Optional administrator-assisted scans

Implementation and signed builds are in place. Ordinary folder scans run as the user. Real system registration/approval and elevated scanning remain unverified; no helper has been registered during development so far.

## Verified platform constraints

- `SMAppService.daemon(plistName:)` is the current native mechanism for registering a privileged helper. Registration requires user authorization and may require approval in System Settings.
- A sandboxed app cannot install an unsandboxed daemon on current macOS. The elevated-capable distribution therefore needs a separate, explicit unsandboxed build configuration; ordinary sandboxed builds must keep working.
- NSXPCListener and NSXPCConnection can enforce peer code-signing requirements on macOS 13+. Both sides must validate the expected identifier and signing team, not only a bundle identifier.
- Unix root privileges do not override all macOS privacy controls. Full Disk Access remains a separate user-controlled setting.
- A development signing identity exists on the current machine. Availability alone does not validate helper installation or authorize approving system permission prompts.

## Implementation requirements

1. Read-only helper using the existing scanner; no arbitrary shell commands, file reads, file writes, Trash, or deletion in its protocol.
2. Explicit app action to enable/register the helper, with visible service status and removal support. Never auto-register at launch.
3. OS authentication for elevated scan authorization, checked by the helper rather than trusted from a UI boolean.
4. Mutually authenticated XPC, cancellation on disconnect, one active scan per connection, and bounded progress transport.
5. Return scan snapshots to the existing UI. Clearly identify elevated results. Keep all file-management actions unprivileged.
6. Test request validation and serialization without root first. Validate the signed helper and real system authorization flow only after the implementation is concrete.

## Primary references

- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Getting Started with SMAppService: sandbox compatibility](https://developer.apple.com/forums/thread/802443)
- [Listener code-signing requirements](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:))
- [Connection code-signing requirements](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))

## Evidence so far

- `scripts/build-direct.sh` builds an explicit unsandboxed release, embeds the read-only helper and launchd plist, signs both with the supplied Apple identity and verifies both signatures.
- `scripts/test-integration.sh <identity>` verifies actual signed anonymous XPC communication, rejection of wrong client/server identifiers, invalid authorization rejection, and binary snapshot serialization. These tests require no root service and do not request administrator rights.
- Regular scanner, layout and Trash tests continue to pass.
- The real access panel was inspected. On this machine the OS reports `.notFound` before first registration; the system log says the BTM service record is absent although the bundle files are valid. The UI now allows explicit registration from this state, reports registration errors, and disables removal until a service is registered/awaiting approval.

Registration and system approval create persistent privileged access. Ask for confirmation immediately before testing that step. The user must complete any OS authentication prompt; never ask them to share a password in chat.
