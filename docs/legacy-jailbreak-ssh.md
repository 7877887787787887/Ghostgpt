# Legacy jailbreak integration (opt-in)

GhostGPT can inspect an **already-jailbroken** iPhone or iPad over a private, authenticated SSH gateway. The iOS app does not exploit iOS, jailbreak the local device, bypass code signing, escape its sandbox, or install a privileged helper. A successful SSH command does not confer privileges on GhostGPT itself.

## Compatibility and trustworthy sources

Check the **exact device model, chip, and iOS version** with the maintainers before attempting a jailbreak:

- Dopamine (official source): https://github.com/opa334/Dopamine
- palera1n (official source): https://github.com/palera1n/palera1n
- palera1n installation and A11 passcode cautions: https://docs.palera.in/installing-palera1n/

Many older iPhones cannot run current iOS releases. GhostGPT currently builds with an **iOS 17.0 minimum deployment target**, so this in-app screen cannot run on an iPhone limited to iOS 16 or earlier. Do not claim otherwise. A separate build targeting older iOS with API compatibility testing is required.

## Setup on a device that you independently jailbroke

1. Back up the device, and follow the official project's compatibility guidance. Avoid unofficial sites claiming that every iOS version is jailbreakable.
2. Install a maintained OpenSSH package using the jailbreak's package manager, where supported. Protect SSH with a unique key, restrict access to your private network, and do not expose port 22 or a root shell publicly.
3. On the trusted Windows PC running `windows/lmstudio_gateway.py`, configure an OpenSSH host alias with the verified host key in `known_hosts` and the correct key-based identity. Example *template*, not a machine address:
   ```sshconfig
   Host legacy-iphone
       HostName YOUR_PRIVATE_DEVICE_ADDRESS
       User root
       IdentityFile ~/.ssh/legacy_device_ed25519
       BatchMode yes
       StrictHostKeyChecking yes
   ```
4. Set the PC gateway process environment `GHOSTGPT_SSH_HOSTS=legacy-iphone`; restart that gateway to load the allow-list. Keep its HTTPS terminal endpoint reachable only over your private network and continue using its separate bearer token.
5. Open **GhostGPT → Tools → Legacy jailbreak & root SSH** or **Settings → Legacy jailbreak / root SSH**, enter `legacy-iphone` as the alias, and select the SSH account that is already configured and authorized on the target.
6. Tap **Check remote SSH root identity** and approve the read-only `id -u` check. A return value of `0` means that **SSH session** is running as root, *not* that GhostGPT itself became root or that the jailbreak is verified. Other UIDs indicate non-root sessions.

The adjacent **Open SSH terminal** screen carries the alias and username. The existing gateway enforces exact host allow-lists and a small read-only command allow-list. It does **not** permit arbitrary privileged shell commands, destructive filesystem modifications, or installing jailbreak packages.

## Security and functionality limits

- On rootless jailbreaks, even an SSH root session cannot simply write the sealed system partition.
- Never enter a root password, signing certificate, SSH private key, or bearer token into the chat.
- Root access is not available to a stock iPhone through an ordinary IPA. A separately installed, version-compatible jailbreak is required for privileged device administration.
- Different devices and OS versions require different official tools; no universal in-app jailbreak is included.
