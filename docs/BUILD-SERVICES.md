# Cheap Mac build services

Prices were checked in October 2026 and change frequently; confirm on the provider's page.
The Apple Developer Program (US$99/year) is separate and required for TestFlight and the App
Store, regardless of which build service you use.

| Service | What you get | Rough price | Best for |
| --- | --- | --- | --- |
| **GitHub Actions `macos-15`** | Fresh macOS VM per job, Xcode 16, our existing workflow | US$0.062/min paid; standard macOS runners are normally free for public repositories — check current GitHub billing | Cheapest CI for this public repo. Our build is about 5–8 minutes. No desktop, so signing needs API keys or a one-time Mac setup |
| **Xcode Cloud** | Apple-hosted CI, managed signing, TestFlight delivery, 25 compute hours/month | Included with the US$99/year Developer Program; 100 h/month US$49.99 | Best fit for App Store delivery without owning a Mac. Connect the GitHub repo, add a workflow, and use the TestFlight post-action |
| **Codemagic** | Hosted macOS CI with M-series machines, 500 free minutes/month on the free tier | Free tier; paid usage around US$0.015–0.04/min depending on machine | Flutter-friendly CI, but works for native Xcode projects too |
| **MacinCloud** | Remote shared or dedicated Mac, hourly or daily pay-as-you-go | From US$1/hour or US$4/day (prepaid credits); shared plan from about US$25/month | A few hours of hands-on Xcode, App Store Connect setup, screenshots or debugging |
| **MacRent** | Dedicated Mac mini M4/M6 with admin, SSH/VNC | US$15/day, US$89/week, US$159/month | A short, real Mac for archive/signing/submission without a subscription |
| **HostMyApple** | Dedicated Mac mini or macOS VPS | VPS from about US$24.99/month; M1 dedicated from US$69.99/month | Cheap monthly Mac with admin access |
| **NoMac** | macOS virtual machine on shared hardware | About US$0.80/hour | Very short experiments; a VM, not a bare-metal Mac |
| **Scaleway Apple Silicon** | Dedicated Mac mini M1 | From €0.11/hour, 24-hour minimum (about €2.64/day) | EU-based short rental; remote desktop |
| **AWS EC2 Mac** | Dedicated Mac host, M1–M4 | Around US$1.20/hour for an M4, 24-hour minimum (about US$29/day) plus storage | Teams already on AWS; not the cheapest for one app |
| **MacStadium** | Dedicated Mac mini/Studio, Orka CI | From about US$109/month for an M2 mini | Reliable long-term CI or a team fleet |
| **RentAMac / Mac Mini Vault / OakHost / MacRun / Macly** | Dedicated Mac minis | Roughly US$119–159/month, or about US$15/day for Macly | Monthly hosting; stock varies, so check availability |

## Recommendation for Ward

1. **Keep GitHub Actions for compile checks and screenshots.** The repository is public, the
   standard macOS runner is normally free for public repos, and the workflow already builds and
   runs the app in the simulator.
2. **Use Xcode Cloud for signed TestFlight/App Store builds.** The 25 included compute hours are
   enough for a small app, and Apple manages distribution certificates and provisioning.
3. If Xcode Cloud is awkward, rent a **MacRent day (US$15)** or a few **MacinCloud hours** once
   to create the App Store distribution certificate and app record, then use the API-key release
   workflow for future uploads.

## What “build service” cannot do for you

- It cannot create your Apple Developer account or accept the Program License Agreement.
- It cannot complete App Store Connect tax/banking or the privacy questionnaire.
- It does not provide a physical iPhone for testing. Use TestFlight on a friend's device.
- A cloud Mac cannot run the iOS Simulator forever; CI jobs are ephemeral by design.
