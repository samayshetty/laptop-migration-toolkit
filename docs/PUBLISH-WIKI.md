# Publishing the wiki

The `wiki/` folder in this repository is ready to be published as the GitHub wiki
of `samayshetty/laptop-migration-toolkit`. GitHub wikis are stored in a separate
git repository - publishing is a one-time copy.

## Option A - publish with git (recommended)

1. Open the repository on GitHub and click **Wiki** -> **Create the first page**
   (this initializes the wiki repository), then save any placeholder page.
2. Clone the wiki repository next to your working copy:

   ```powershell
   git clone https://github.com/samayshetty/laptop-migration-toolkit.wiki.git
   ```

3. Copy all pages and push:

   ```powershell
   Copy-Item .\wiki\*.md .\laptop-migration-toolkit.wiki\ -Force
   Set-Location .\laptop-migration-toolkit.wiki
   git add .
   git commit -m "Publish wiki documentation"
   git push
   Set-Location ..
   ```

4. `Home.md` automatically becomes the wiki landing page.

## Option B - publish from the web UI

Open each file in `wiki/` (view the raw content), create a wiki page with the
same name in the GitHub UI, and paste the content:

Home, First-Time-Setup, Getting-Started, Collect-from-the-Old-Laptop, Verify-the-Package,
Restore-on-the-New-Laptop, App-Selection-and-Granularity,
Conflicts-and-Version-Mismatch, Security-and-Privacy, No-Administrator-Rights,
Troubleshooting, FAQ.

## Updating later

Re-run the copy + commit + push from Option A whenever `wiki/` changes.
