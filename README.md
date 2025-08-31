# Spring Petclinic - Secure CI/CD with JFrog (DevSecOps)

This repo demonstrates a **secure, traceable pipeline** for the Spring Petclinic app using **GitHub Actions** and **JFrog Platform**:

* Build & test the app
* Generate a **CycloneDX SBOM**
* (Safe events) run **JFrog Xray** scans (non-blocking gates)
* Publish **JAR** to Artifactory (Maven snapshots)
* Build & push **Docker image** to a **dev/quarantine** Docker repo
* Record an **image mapping** (commit ↔ tags ↔ digest)
* Store **SBOM**, **image mapping**, and **Xray summaries** in a **Generic audit** repo
**Azure Bicep** IaC + GitHub OIDC workflow to deploy your JFrog-hosted container to **Azure Web App**.

All artifacts & images are **commit-centric** for strong traceability.

---

## CI/CD at a glance

* **Workflow:** `.github/workflows/ci-jar-and-docker.yml`
* **Jobs:**

  1. **JAR & SBOM**

     * stamps `project.version` as `…-g<sha7>-SNAPSHOT`
     * `mvn clean verify`
     * generates **CycloneDX** SBOM
     * (push to main) **deploys JAR** to Artifactory snapshots
     * (safe events) **Xray** dependency + JAR scans (non-blocking)
     * uploads SBOM and reports to **JFrog Generic** audit repo
  2. **Docker (requires approval)**

     * downloads the JAR from Job 1
     * builds and pushes image → **dev/quarantine** repo with tags:

       * `git-<sha7>` (immutable trace to commit)
       * `<branch>-latest` (moving pointer)
     * captures the **digest** and writes **image-mapping.json**
     * queries **Xray registry summary** (non-blocking)
     * uploads mapping + summary to **JFrog Generic** audit repo

> **Note:** Snapshots in Maven will include a timestamp/build number (e.g., `…-gabc1234-20250828.104354-1.jar`). That’s correct and desired. Your **commit id is embedded** in every jar name and in the **image tag** `git-<sha7>`.

---

## What gets created (where)

### In **Artifactory (Maven snapshots)**

```
org/springframework/samples/spring-petclinic/<version>/...
  ├─ spring-petclinic-<version>.jar      # e.g., 3.5.0-gabc1234-2025...-1.jar
  ├─ spring-petclinic-<version>.pom
  └─ checksums + maven-metadata.xml
```

### In **Artifactory (Docker dev/quarantine)**

```
<DOCKER_DEV_REPO>/<IMAGE_NAME>
  tags:
    - git-<sha7>
    - <branch>-latest
  (manifest + layers; Xray indexes automatically if enabled)
```

### In **Artifactory (Generic audit)**

```
generic-audit-local/
  sboms/petclinic/<commit>/cyclonedx.json
  mappings/petclinic/<commit>/image-mapping.json
  xray/images/spring-petclinic/<commit>/<sha256__...>/xray-image-summary.json
```

### In **GitHub Artifacts** (for quick retrieval)

* `app-jar-<github_sha>` → the exact JAR used for the image (e.g., `spring-petclinic-g<sha7>.jar`)
* `sbom-<github_sha>` → `cyclonedx.json` (or `bom.json`, normalized)
* `xray-json-<github_sha>` → `xray-deps.json`, `xray-jar.json`
* `image-dev-<github_sha>` → `image-mapping.json`, `xray-image-summary.json`

---

## Prerequisites

### GitHub → **Settings → Secrets and variables → Actions**

**Secrets**

* `JFROG_USER` – JFrog username or service account
* `JFROG_TOKEN` – JFrog access token with:

  * **deploy/read** on your Maven snapshots repo
  * **push/pull** on your Docker dev/quarantine repo
  * **write** on your Generic audit repo

**Variables**

* `JF_URL` – e.g. `https://*****.jfrog.io`
* `JF_MVN_SNAPSHOTS_REPO` – e.g. `petclinic-mvn-snapshots-local`
* `JF_GENERIC_AUDIT_REPO` – e.g. `generic-audit-local`
* `JF_DOCKER_REGISTRY` – e.g. `*****.jfrog.io`
* `DOCKER_DEV_REPO` – e.g. `petclinic-docker-dev-local`
* `IMAGE_NAME` – e.g. `spring-petclinic`

### GitHub → **Settings → Environments**

Create an environment named **`docker-build`** and require reviewer approval.
The Docker job waits for this approval before pushing images.

### JFrog setup

* Maven **snapshots** repo (allow deploy)
* Docker **dev/quarantine** repo (Xray indexed if you want registry scans)
* **Generic** repo for SBOMs/mappings/reports
* Xray enabled on the relevant repos

---

## How to run it

### 1) Trigger CI

* **Pull Request** to `main`: builds/test/SBOM; scans run only if PR originates from same repo (for secret safety).
* **Push** to `main`: builds/test/SBOM → **deploy JAR** → request **approval** → **build & push** Docker image.

You can also trigger **manually** via the “Run workflow” button.

### 2) Approve Docker build

When the first job succeeds, GitHub surfaces an environment approval (for `docker-build`). Approve it to let the image push proceed.

### 3) Pull & run locally

```bash
# login to JFrog registry
docker login *****.jfrog.io -u "$JFROG_USER" -p "$JFROG_TOKEN"

# pull by commit tag
docker pull *****.jfrog.io/<DOCKER_DEV_REPO>/<IMAGE_NAME>:git-<sha7>

# run
docker run --rm -p 8080:8080 \
  *****.jfrog.io/<DOCKER_DEV_REPO>/<IMAGE_NAME>:git-<sha7>

# app will be available on http://localhost:8080/
```

### 4) Run the app from source (optional)

```bash
# Java 17 required
./mvnw spring-boot:run
# or
mvn spring-boot:run
```

---

## Traceability model (commit-first)

* **JAR version** is rewritten to `…-g<sha7>-SNAPSHOT` before build
  → remote snapshot filenames contain the **commit** and a Maven **unique timestamp**.
* **Docker tags** include:

  * immutable: `git-<sha7>`
  * moving: `<branch>-latest`
* **Mapping** (`image-mapping.json`) stores **commit ↔ tags ↔ digest** so promotion can verify it’s the **same content**.

---

## DevSecOps controls in this repo

* **SBOM** (CycloneDX) generated on every build and archived in **JFrog Generic**.
* **Xray**:

  * Dependency scan (Maven) and **binary JAR** scan (non-blocking) on push/safe PRs.
  * Optional **registry summary by digest** after image push (non-blocking).
  * You can make these **hard gates** in a separate **Promote to prod** workflow.
* **Reproducible builds**: build timestamp fixed from the last commit time.
* **Least-privilege tokens**: only the three repos require access.
* **Audit trail**: SBOMs, Xray JSONs, mapping JSONs are retained in JFrog under **commit paths**.

---

## Deploy to Azure Web App (Linux, Container)

Use **Bicep + OIDC** workflow to deploy the JFrog image directly to **Azure**.

Files
```
Bicep: infra/appservice-webapp.bicep
Workflow: .github/workflows/deploy-azure-webapp.yml
Azure OIDC (no cloud secrets in GitHub)
Create a Microsoft Entra App Registration, add a Federated Credential:
Issuer: https://token.actions.githubusercontent.com
Subject (choose one):
Branch: repo:AzureEP/demo:ref:refs/heads/main
Environment: repo:AzureEP/demo:environment:docker-build
Audience: api://AzureADTokenExchange
```
Give the app’s service principal Contributor on your target RG.

GitHub Secrets required for deployment

  * **AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID**

  * **JFROG_USER, JFROG_TOKEN**

**Run the deployment workflow**

  * Actions → Deploy to Azure Web App (JFrog container) → Run:
```
    resource_group: e.g. jfrogdemotest
    location: e.g. East US 2
    webapp_name: globally unique
    plan_sku / plan_tier: e.g. B3 / Basic
    container_image: full ref from JFrog
    Tag: YOURORG.jfrog.io/<DOCKER_DEV_REPO>/<IMAGE_NAME>:git-<sha7>
    or digest (recommended): …@sha256:<digest>
    port: usually 8080
```
**Result:**
  * https://<webapp_name>.azurewebsites.net

## Files of interest

* `.github/workflows/ci-jar-and-docker.yml` - main CI workflow
* `docker/Dockerfile.from-jar` - runtime image built from the JAR (non-root, OCI labels)
* `.github/workflows/ci-jar-and-docker.yml` - main CI
* `.github/workflows/deploy-azure-webapp.yml` - deploy to Azure Web App
* `docker/Dockerfile.from-jar` - runtime image from prebuilt JAR
* `infra/appservice-webapp.bicep` - App Service plan + Web App (container)

---

## License

Spring Petclinic is maintained by the Spring community under the **Apache 2.0** license.