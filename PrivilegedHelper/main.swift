import Foundation
import Darwin

// launchd is the only supported root launcher. No shell, sudo, or argument-based bypass modes.
guard geteuid() == 0 else {
    fputs("MacDirStat Scanner must be launched by its authorized system service.\n", stderr)
    exit(EXIT_FAILURE)
}
do {
    let requirement = try PeerSigning.requirement(identifier: ElevatedConfiguration.appIdentifier)
    let delegate = ListenerDelegate(clientRequirement: requirement)
    let listener = NSXPCListener(machServiceName: ElevatedConfiguration.helperIdentifier)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = delegate
    listener.resume()
    withExtendedLifetime(delegate) { RunLoop.current.run() }
} catch {
    fputs("MacDirStat Scanner could not validate its signature.\n", stderr)
    exit(EXIT_FAILURE)
}
