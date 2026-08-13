# JoynVision — installer downloads

Public download location for the **JoynVision Edge** installer, the component
that runs on a shop's own till PC.

**The product source is not here.** This repository contains release binaries
and nothing else.

## Download

Get the latest `JoynVision-Edge-Setup-*.exe` from
[Releases](../../releases/latest).

## Installing

1. Sign in to your JoynVision dashboard.
2. Go to **Settings → Install on a PC** and generate a **pairing code**.
3. Run the installer on the till PC and type that code. It is the only thing
   the installer asks for.

The pairing code expires after 24 hours and works once.

## Is this safe to download publicly?

The installer contains **no credentials and no customer data**. Everything it
needs — server address, site key, broker username and password — is delivered
by the server at the moment a pairing code is redeemed, and that code is itself
the credential. An installer without a valid code cannot connect to anything.

## Verifying what you downloaded

Every release lists the SHA-256 of its installer. On Windows:

```powershell
Get-FileHash .\JoynVision-Edge-Setup-<version>.exe -Algorithm SHA256
```

## Windows SmartScreen

The installer is not yet code-signed, so Windows may show
*"Windows protected your PC"*. Choose **More info → Run anyway**. Verify the
SHA-256 above first if you want to be certain of what you are running.
