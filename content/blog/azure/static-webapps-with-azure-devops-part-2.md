---
title: "Static Webapps With Azure Devops Part 2"
date: 2022-07-17T08:01:38+02:00
draft: true
comment_id: 2
showtoc: true
---

In the first part 
The contents of all the files can be seen on [GitHub](TODO).


### Build and test our code
This pipeline YAML is getting quite unwieldy, so let's split the stages up into templates.
We'll change the `.azuredevops` structure to reflect the following:

```txt
/
├─┬ .azuredevops
│ ├── 0-ci.yml      # the entrypoint / pipeline definition
│ ├── 1-infra.yml   # the deploy_infra stage template
│ ├── 2-build.yml   # the build_test stage template
│ ├── 3-deploy.yml  # the deploy_code stage template
```

Then we can define our `0-ci.yml` as such:

```yaml
stages:
  template: '1-infra.yml'
  template: '2-build.yml'
  template: '3-deploy.yml'
```

Depending on what language you write your API in, you can use different tasks. This project uses JavaScript, so we'll use
node to build and test our API.

### Deploy the code
