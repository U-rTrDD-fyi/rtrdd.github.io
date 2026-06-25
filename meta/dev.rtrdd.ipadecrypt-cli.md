**ipadecrypt-cli** is an on-device IPA decryptor for jailbroken iOS. It dumps decrypted Mach-O images — the main executable, frameworks, and appex plug-ins — from an installed app and repackages them into a plaintext `.ipa`.

Ships two commands:

- **ipadecrypt** — the core decryptor (`decrypt` / `version` subcommands).
- **decrypt** — a convenience wrapper that resolves the installed `.app` from a bundle id, names the output IPA, and (with `--scan`) verifies every binary's cryptid via `otool`.

**Usage**

```
decrypt com.openai.chat /var/mobile/Documents/ipadecrypt
decrypt --scan com.openai.chat /var/mobile/Documents/ipadecrypt
```
