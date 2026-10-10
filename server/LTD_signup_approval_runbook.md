# LangTech Depot — Approving Sign-ups (Runbook)

**For:** Doug (cover while Jim is offline, roughly 8 hours a night in Sydney)
**Owner:** Jim Henderson · **Last updated:** Saturday, 10 Oct 2026
**Items marked ⟦TBC⟧ need Jim to fill in before handing over.**

---

## 1. Why this step exists

Since PR #29 (launch-readiness fixes), a person has to approve each new receiver of the Depot installers before they get access. It closes the security hole where someone could switch a read-only folder to send/receive and push content to every subscriber. Our earlier sync methods never had this step, so only new users will notice it.

What this means for users:

- The browser **no longer shows a code** when someone registers. The code is **only emailed**, and only **after** an admin approves them.
- Until someone approves them, the user receives nothing. A missing email almost always means "not approved yet", not a mail fault.

## 2. How the flow works

1. A user registers on the Depot site (depot.langtech.cloud).
2. The registration service (`register.py`, running as `langtechdepot-register`) emails an **approval request** to the admin mailbox **depot@langtech.cloud**.
3. That email contains a ready-made command, for example:
   ```
   ltd-sync-admin approve wwBYgEAxxxx9ZFfQaEpqbw
   ```
   Each sign-up gets its own token.
4. An admin runs the command on the Depot server.
5. The server emails the user from depot@langtech.cloud with their code, and they carry on with setup.

## 3. Getting the approval emails (pick one)

Without a change, approval requests reach only the depot@langtech.cloud mailbox, which Jim checks. Choose one of these:

| Option | How | Notes |
|---|---|---|
| **A. Forward to Doug** (recommended) | Jim has already added a forward from depot@langtech.cloud to Doug's address. Zoho has sent Doug a **verification code**. Doug sends the code to Jim, or enters it himself, in the Zoho web UI. | Once confirmed it needs no further action and can stay on for good. |
| **B. Change the admin address on the server** | Edit `register.env` so approval mail goes to Doug, then restart the service (see §5). | Temporary. **Change it back afterwards**, or Jim stops getting requests. |
| **C. Log into the mailbox directly** | Web: mail.zoho.com as depot@langtech.cloud. | Share the password through a password manager or another private channel, **not Slack**. ⚠️ The password was posted in the Slack DM on 9 Oct, so I have changed it and will reshare it privately some time. |

Jim's own client setup, for reference: Thunderbird, IMAP `imappro.zoho.com`, port 993, SSL/TLS, normal password.

## 4. Approving a sign-up

1. Open the approval request email in depot@langtech.cloud (or in your forwarded copy).
2. **Decide whether to approve.** ⟦TBC: approval policy, e.g. SIL/partner addresses approved on sight, anything else checked with Jim or Doug first.⟧ Recent approvals: doug_higby@sil.org, eric_hays@sil.org.
3. If approving, copy the command from the email to the clipboard and
3. SSH to the Depot server: ⟦host and login, e.g. `ssh doug@depot.langtech.cloud`⟧
4. Paste the command from the email exactly as written:
   ```
   ltd-sync-admin approve <token-from-email>
   ```
   ⟦TBC: whether it needs `sudo`. It is installed root-owned and mode 755 in `/usr/local/bin`.⟧
5. The command makes the server email the user their code. Optionally, let the user know it's on its way and to check their spam folder.

## 5. register.env: handle with care

Location: ⟦TBC: full path, e.g. `/opt/langtechdepot/register.env`⟧

- **Ownership and permissions:** the group must be `syncthing` with mode `640`. `register.py` runs as `syncthing` and can't start if it can't read the file. If an editor resets the permissions, restore them:
  ```
  sudo chgrp syncthing register.env && sudo chmod 640 register.env
  ```
- **`GUARD_MODE` must be set.** It is currently `GUARD_MODE=report`. If the key is missing, the code **defaults to `enforce`** and the guard starts cutting devices off immediately. Don't delete this line when editing. Switching to `enforce` is Jim's job after the report-mode trial day, so leave it alone.
- **Admin email variable** (for option B): ⟦TBC: variable name⟧
- **After any edit**, restart and check:
  ```
  sudo systemctl restart langtechdepot-register
  sudo systemctl status langtechdepot-register
  ```

## 6. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| User says "no email arrived" | Usually not approved yet. Look for their approval request and run §4. Then ask them to check spam. |
| Email still missing after approval | langtech.cloud has an SPF record but **no DKIM record**, so some mail servers may junk or drop the message. Ask the user to check spam or quarantine. A DKIM record is the long-term fix ⟦TBC: owner⟧. |
| Someone already registered signs up again | Unconfirmed whether a repeat sign-up raises a new request (Doug asked on 8 Oct). ⟦TBC⟧ |
| Service won't start after editing register.env | Check permissions in §5 and run `journalctl -u langtechdepot-register -n 50`. |
| No approval requests arriving at all | Check the service is running (`systemctl status`) and that the admin address in register.env is correct. |

## 7. Hand-back

When Jim is online again, tell him in Slack whom you approved. If you used option B, confirm that register.env has been changed back.

---

*Possible later improvement (Doug, 8 Oct): automate the email step. Approval was made manual because of the security issue.*
