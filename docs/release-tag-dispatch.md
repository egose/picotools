# Release Tag Dispatch Workflow

When creating a new tag using the repository’s default `GITHUB_TOKEN`, the resulting tag event usually does **not** start the downstream `release.yml` workflow.
To make the tag push trigger the release workflow, this repository uses an **SSH deploy key** and pushes the tag over git/SSH.

## Steps

1. **Generate a new OpenSSH key**:

   ```sh
   ssh-keygen -t ed25519 -f id_ed25519 -N "" -q -C ""
   ```

   This creates:
   - A private key file: `id_ed25519`
   - A public key file: `id_ed25519.pub`
     in the current working directory.

2. **Add the private key** to the repository’s **Secrets** in GitHub.
   - Name it: `SSH_KEY`

3. **Add the public key** to the repository’s **Deploy Keys** in GitHub.
   - Name it: `SSH_KEY`
   - Enable `Allow write access` if you plan to push changes.

4. Update Repository Settings
   1. Go to your GitHub repository.
   2. Click **Settings** (top tab) -> **Actions** -> **General**.
   3. Scroll down to **Workflow permissions**.
   4. Toggle the checkbox: **"Allow GitHub Actions to create and approve pull requests"**.
   5. Click **Save**.

5. **Update your GitHub Actions workflow** to use the SSH key and push the tag:
   ```yaml
   jobs:
     tag-changelog:
       runs-on: ubuntu-22.04
       permissions:
         contents: write
         issues: write
         pull-requests: write
       steps:
          - uses: actions/checkout@v4
            with:
              ssh-key: ${{ secrets.SSH_KEY }}
              fetch-depth: 0

          - name: Create and push release tag
            run: |
              git tag -a v1.2.3 -m "Release v1.2.3"
              git push origin refs/tags/v1.2.3
    ```
