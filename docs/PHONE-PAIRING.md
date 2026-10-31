# Pair Magpie from an SSH terminal

On Enterprise, run:

```sh
~/.local/bin/omamail phone pair
```

A successful result says `Pairing code:` followed by 6 digits. On the same iPhone, switch to Magpie, open **Settings → Enterprise**, and enter those digits. The code expires in 5 minutes and works once. Requesting another code replaces the previous code. Enterprise's desktop can stay locked.

Check the connection from your SSH terminal:

```sh
~/.local/bin/omamail phone list
```

A successful pairing appears by name with a device ID. An empty list says no iPhones are connected. Pairing connects Enterprise's AI, shared snooze and notification services; it does not establish that Apple has delivered a notification. Ordinary Gmail reading on the phone works independently.

To disconnect one phone, copy its full device ID from the list:

```sh
~/.local/bin/omamail phone disconnect DEVICE_ID
~/.local/bin/omamail phone disconnect DEVICE_ID --execute
```

The first command previews the change and prints the complete command to apply it. The second disconnects that phone from Enterprise and confirms its name. Mail already on the iPhone is unchanged, and you can pair it again later. Other phones stay connected.

## Setup and troubleshooting

The Enterprise mail service must already be enabled and running with its iPhone listener configured. The commands never start another mail engine, open the live mail database, restart the desktop or create an account. Run them as the same Linux user who runs Magpie. SSH sessions do not need desktop display variables or a session bus; without `XDG_RUNTIME_DIR`, the CLI finds the current user's private systemd runtime directory.

For another installation, enable the CLI from Magpie's existing Install CLI control, or run `python3 scripts/backend-runtime.py enable-cli` from its installed plugin directory. That creates `~/.local/bin/omamail` pointing to the exact private backend. No PATH backend is substituted. `disable-cli` removes that owned link.

If a response times out or the connection is lost, the command reports that the result could not be confirmed. Check `phone list` after a disconnection, or request a fresh code with `phone pair`. Mutations are not retried automatically. A lost reply can mean the service applied the request.

Add `--json` for the normal `{"ok":true,"result":...}` envelope; failures use `{"ok":false,"error":{"code":"..."}}` and exit 1. Invalid arguments exit 2. Pairing codes appear only in the requested output, never in process arguments or stderr. Connected-phone output contains names and device IDs, not access tokens. Treat a pairing code as private until it expires.
