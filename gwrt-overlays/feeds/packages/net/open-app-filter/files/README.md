# Bundled OAF feature library

- Version: 26.11.11
- Format: v4.0
- Applications: 565
- Size: 31,372 bytes
- SHA-256: `e06862803f4fa31a87c96715b845da018e91903ececd59fa4305f1409a12146f`

`feature.bin` is the current router's feature database. The package verifies its
hash and installs it at `/etc/fwxd/feature.bin`. No account key or router UCI
configuration is included.

GWRT excludes the online updater from the daemon and removes its API and LuCI
controls. The bundled database loads locally; custom application rules remain
available. Updating this bundled version requires an explicit source change.
