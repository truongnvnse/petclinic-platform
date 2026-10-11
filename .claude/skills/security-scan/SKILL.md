---
name: security-scan
description: Run Checkov security scan on Terraform modules
disable-model-invocation: true
argument-hint: "[module|all]"
---

# /security-scan [module|all]

Run a Checkov security scan on Terraform code and categorize findings.

## Arguments

- `module` — Specific module to scan (e.g., `vpc`, `eks`, `rds`) or `all` for everything
- Default: `all`

## Steps

1. Determine the scan target:
   - Specific module → `terraform/modules/{module}/`
   - `all` → `terraform/`

2. Verify the target directory exists and contains .tf files.

3. Run the Checkov scan:
   `uvx checkov -d {target} --framework terraform --output json`

4. Categorize findings into severity levels:
   - **Critical**: Public access, missing encryption, wildcard IAM
   - **High**: Missing tags, no logging, weak security groups
   - **Medium**: Non-ideal configurations, missing best practices
   - **Low**: Style issues, informational

5. Present results:
   ```
   ## Security Scan: {target}

   Passed: {N} | Failed: {N} | Skipped: {N}

   ### Critical ({N})
   - CKV_AWS_xxx: {description} — {file}

   ### High ({N})
   ...

   ### Recommended Actions
   1. {First thing to fix}
   2. {Second thing to fix}
   ```

6. If there are Critical findings, emphasize: "Fix critical issues before applying to any environment."

## Important

- This is a read-only scan — it does not modify any files
- Checkov may flag intentional configurations — note these as acceptable exceptions
- For a comprehensive audit, use the security-auditor agent instead
