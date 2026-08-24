#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_COMMIT_REMOTE_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_COMMIT_REMOTE_SH_LOADED=1

# Contract: remote/PR helpers take scalar inputs and return nonzero on Git or
# API failures. PR context is written to a caller-owned associative array. API
# response validation is centralized here and never prints response bodies.
# Required dependencies: run_git_api, debug_log, json_read_string, plan helpers.
current_branch_name() {
  local branch

  branch=$(git branch --show-current)
  if [ -z "$branch" ]; then
    echo 'Error: detached HEAD is not supported' >&2
    return 1
  fi

  printf '%s\n' "$branch"
}

github_repo_from_remote_url() {
  local remote_url="$1"
  local repo=''

  case "$remote_url" in
  git@github.com:*)
    repo=${remote_url#git@github.com:}
    repo=${repo%.git}
    ;;
  ssh://git@github.com/*)
    repo=${remote_url#ssh://git@github.com/}
    repo=${repo%.git}
    ;;
  https://github.com/*.git)
    repo=${remote_url#https://github.com/}
    repo=${repo%.git}
    ;;
  https://github.com/*)
    repo=${remote_url#https://github.com/}
    ;;
  esac

  if [ -z "$repo" ]; then
    echo "Error: unsupported GitHub remote URL: ${remote_url:-<missing>}" >&2
    return 1
  fi

  printf '%s\n' "$repo"
}

github_repo_from_remote_url_optional() {
  local remote_url="$1"

  github_repo_from_remote_url "$remote_url" 2>/dev/null || true
}

git_remote_fetch_url() {
  local remote="$1"
  local remote_url

  remote_url=$(git remote get-url "$remote" 2>/dev/null || true)
  if [ -z "$remote_url" ]; then
    echo "Error: unable to determine fetch URL for remote '$remote'" >&2
    return 1
  fi

  printf '%s\n' "$remote_url"
}

git_remote_push_url() {
  local remote="$1"
  local remote_url

  remote_url=$(git remote get-url --push "$remote" 2>/dev/null || true)
  if [ -z "$remote_url" ]; then
    echo "Error: unable to determine push URL for remote '$remote'" >&2
    return 1
  fi

  printf '%s\n' "$remote_url"
}

resolve_push_remote() {
  local branch="$1"
  local remote
  local -a remotes=()

  remote=$(git config --get "branch.$branch.pushRemote" 2>/dev/null || true)
  if [ -n "$remote" ]; then
    printf '%s\n' "$remote"
    return 0
  fi

  remote=$(git config --get remote.pushDefault 2>/dev/null || true)
  if [ -n "$remote" ]; then
    printf '%s\n' "$remote"
    return 0
  fi

  if git remote get-url origin >/dev/null 2>&1; then
    printf 'origin\n'
    return 0
  fi

  mapfile -t remotes < <(git remote)
  if [ "${#remotes[@]}" -eq 1 ]; then
    printf '%s\n' "${remotes[0]}"
    return 0
  fi

  echo "Error: unable to determine push remote for branch '$branch'" >&2
  return 1
}

resolve_effective_push_remote() {
  local branch="$1"
  local upstream

  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
  if [[ "$upstream" == */* ]]; then
    printf '%s\n' "${upstream%%/*}"
    return 0
  fi

  resolve_push_remote "$branch"
}

pull_request_head_ref() {
  local base_owner="$1"
  local head_owner="$2"
  local branch="$3"

  if [ "$head_owner" != "$base_owner" ]; then
    printf '%s:%s\n' "$head_owner" "$branch"
    return 0
  fi

  printf '%s\n' "$branch"
}

push_current_branch() {
  local branch="$1"
  local remote

  if git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
    debug_log "Pushing branch '$branch' to its configured upstream"
    git push
    return 0
  fi

  remote=$(resolve_push_remote "$branch") || return 1
  debug_log "Pushing branch '$branch' to '$remote' and setting upstream"
  git push -u "$remote" "$branch"
}

planned_commit_titles() {
  local plan_json="$1"
  local scope="$2"
  local count commit_index type message title

  count=$(plan_commit_count "$plan_json")
  commit_index=0
  while [ "$commit_index" -lt "$count" ]; do
    type=$(printf '%s' "$plan_json" | jq -r ".commits[$commit_index].type // empty")
    message=$(printf '%s' "$plan_json" | jq -r ".commits[$commit_index].message // empty")
    title=$(format_commit_title "$type" "$scope" "$message")
    printf '%s\n' "$title"
    commit_index=$((commit_index + 1))
  done
}

pull_request_title() {
  local plan_json="$1"
  local scope="$2"
  local count commit_index type message first_type

  count=$(plan_commit_count "$plan_json")

  if [ "$count" -eq 1 ]; then
    type=$(printf '%s' "$plan_json" | jq -r '.commits[0].type // empty')
    message=$(printf '%s' "$plan_json" | jq -r '.commits[0].message // empty')
    format_commit_title "$type" "$scope" "$message"
    return 0
  fi

  first_type=$(printf '%s' "$plan_json" | jq -r '.commits[0].type // empty')
  local -a messages=()
  commit_index=0
  while [ "$commit_index" -lt "$count" ]; do
    message=$(printf '%s' "$plan_json" | jq -r ".commits[$commit_index].message // empty")
    messages+=("$message")
    commit_index=$((commit_index + 1))
  done

  local joined
  if [ "${#messages[@]}" -le 3 ]; then
    joined=$(printf '%s, ' "${messages[@]}")
    joined=${joined%, }
  else
    joined=$(printf '%s, ' "${messages[@]:0:2}")
    joined="${joined}and $((count - 2)) more"
  fi

  if [ -n "$scope" ]; then
    printf '%s(%s): %s\n' "$first_type" "$scope" "$joined"
  else
    printf '%s: %s\n' "$first_type" "$joined"
  fi
}

pull_request_body() {
  local plan_json="$1"
  local scope="$2"
  local title body='Automated PR created by git-commit.'

  while IFS= read -r title; do
    [ -n "$title" ] || continue
    body+=$'\n- '
    body+="$title"
  done < <(planned_commit_titles "$plan_json" "$scope")

  printf '%s\n' "$body"
}

planned_pull_request_title() {
  local plan_json="$1"
  local scope="$2"
  local existing_title="${3:-}"
  local title

  title=$(json_read_string "$plan_json" '.pull_request.title // empty')
  if [ -n "$title" ]; then
    printf '%s\n' "$title"
    return 0
  fi

  if [ -n "$existing_title" ]; then
    printf '%s\n' "$existing_title"
    return 0
  fi

  pull_request_title "$plan_json" "$scope"
}

planned_pull_request_body() {
  local plan_json="$1"
  local scope="$2"
  local existing_body="${3:-}"
  local body fallback_body

  body=$(json_read_string "$plan_json" '.pull_request.body // empty')
  if [ -n "$body" ]; then
    printf '%s\n' "$body"
    return 0
  fi

  if [ -n "$existing_body" ]; then
    fallback_body=$(pull_request_body "$plan_json" "$scope")
    printf '%s\n\n%s\n' "$existing_body" "$fallback_body"
    return 0
  fi

  pull_request_body "$plan_json" "$scope"
}

create_pull_request() {
  local branch="$1"
  local plan_json="$2"
  local scope="$3"
  local owner="$4"
  local name="$5"
  local base_branch="$6"
  local head_owner="$7"
  local head_ref="$8"
  local existing_pr_url="${9:-}"
  local existing_pr_number="${10:-}"
  local existing_pr_title="${11:-}"
  local existing_pr_body="${12:-}"
  local repo title body response pr_url refreshed_pr_response

  repo="$owner/$name"

  find_existing_pull_request_response refreshed_pr_response "$owner" "$name" "$head_owner" "$branch" "$base_branch" || return 1
  if [ -n "$refreshed_pr_response" ]; then
    existing_pr_url=$(pull_request_url_from_list_response "$refreshed_pr_response")
    existing_pr_number=$(pull_request_number_from_list_response "$refreshed_pr_response")
    existing_pr_title=$(pull_request_title_from_list_response "$refreshed_pr_response")
    existing_pr_body=$(pull_request_body_from_list_response "$refreshed_pr_response")
  fi

  title=$(planned_pull_request_title "$plan_json" "$scope" "$existing_pr_title")
  body=$(planned_pull_request_body "$plan_json" "$scope" "$existing_pr_body")

  if [ -n "$existing_pr_url" ] && [ -n "$existing_pr_number" ]; then
    debug_log "Updating existing pull request for '$branch' into '$base_branch': $existing_pr_url"
    response=$(run_git_api pulls/update "$owner" "$name" "$existing_pr_number" \
      --field "title=$title" \
      --field "body=$body") || return 1
    validate_pull_request_response_url "$response" 'pulls/update' pr_url || return 1
    printf '\033[1;32mPull request updated:\033[0m %s\n' "$pr_url"
    return 0
  fi

  debug_log "Creating pull request for '$branch' into '$base_branch' on '$repo'"
  response=$(run_git_api pulls/create "$owner" "$name" \
    --field "title=$title" \
    --field "head=$head_ref" \
    --field "base=$base_branch" \
    --field "body=$body") || return 1
  validate_pull_request_response_url "$response" 'pulls/create' pr_url || return 1
  printf '\033[1;32mPull request:\033[0m %s\n' "$pr_url"
}

find_existing_pull_request_response() {
  local output_ref_name="$1"
  local owner="$2"
  local repo_name="$3"
  local head_owner="$4"
  local branch="$5"
  local base_branch="$6"
  local response

  printf -v "$output_ref_name" '%s' ''

  response=$(run_git_api pulls/list "$owner" "$repo_name" \
    --state open \
    --head "$head_owner:$branch" \
    --base "$base_branch") || {
    echo 'Error: git-api pulls/list failed while checking for an existing pull request' >&2
    return 1
  }

  validate_pull_request_list_response "$response" || return 1
  if pull_request_json_expr_is_true "$response" 'length == 0'; then
    return 0
  fi

  printf -v "$output_ref_name" '%s' "$response"
}

validate_pull_request_list_response() {
  local response="$1"

  if ! pull_request_json_expr_is_true "$response" 'type == "array"'; then
    echo 'Error: git-api pulls/list response must be a JSON array' >&2
    return 1
  fi
  if pull_request_json_expr_is_true "$response" 'length == 0'; then
    return 0
  fi
  if ! pull_request_json_expr_is_true "$response" '.[0] | type == "object"'; then
    echo 'Error: git-api pulls/list response item must be a JSON object' >&2
    return 1
  fi
  if ! pull_request_json_expr_is_true "$response" '.[0].html_url | type == "string" and length > 0'; then
    echo 'Error: git-api pulls/list response item missing html_url' >&2
    return 1
  fi
  if ! pull_request_json_expr_is_true "$response" '.[0].number | ((type == "number") or (type == "string" and length > 0))'; then
    echo 'Error: git-api pulls/list response item missing number' >&2
    return 1
  fi
  if ! pull_request_json_expr_is_true "$response" '((.[0].title == null) or (.[0].title | type == "string"))'; then
    echo 'Error: git-api pulls/list response item title must be a string when present' >&2
    return 1
  fi
  if ! pull_request_json_expr_is_true "$response" '((.[0].body == null) or (.[0].body | type == "string"))'; then
    echo 'Error: git-api pulls/list response item body must be a string when present' >&2
    return 1
  fi
}

pull_request_json_expr_is_true() {
  local json_text="$1"
  local jq_expression="$2"

  jq -e "$jq_expression" >/dev/null 2>&1 <<<"$json_text"
}

validate_pull_request_response_url() {
  local response="$1"
  local operation="$2"
  local output_ref_name="$3"
  local url

  if ! pull_request_json_expr_is_true "$response" 'type == "object"'; then
    echo "Error: git-api $operation response must be a JSON object" >&2
    return 1
  fi

  if ! pull_request_json_expr_is_true "$response" '.html_url | type == "string" and length > 0'; then
    echo "Error: git-api $operation response missing html_url" >&2
    return 1
  fi

  url=$(json_read_string "$response" '.html_url')
  printf -v "$output_ref_name" '%s' "$url"
}

pull_request_url_from_list_response() {
  local response="${1:-}"

  if [ -z "$response" ]; then
    return 0
  fi

  json_read_string "$response" '.[0].html_url // empty'
}

pull_request_number_from_list_response() {
  local response="${1:-}"

  if [ -z "$response" ]; then
    return 0
  fi

  json_read_string "$response" '.[0].number // empty'
}

pull_request_title_from_list_response() {
  local response="${1:-}"

  if [ -z "$response" ]; then
    return 0
  fi

  json_read_string "$response" '.[0].title // empty'
}

pull_request_body_from_list_response() {
  local response="${1:-}"

  if [ -z "$response" ]; then
    return 0
  fi

  json_read_string "$response" '.[0].body // empty'
}

default_branch_from_git_api() {
  local owner="$1"
  local repo_name="$2"
  local response branch

  response=$(run_git_api repos/get "$owner" "$repo_name" 2>/dev/null || true)
  if [ -z "$response" ]; then
    return 1
  fi

  branch=$(printf '%s' "$response" | jq -r '.default_branch // empty' 2>/dev/null || true)
  if [ -z "$branch" ]; then
    return 1
  fi

  printf '%s\n' "$branch"
}

default_branch_from_git() {
  local remote="$1"
  local ref line output

  ref=$(git symbolic-ref --quiet --short "refs/remotes/${remote}/HEAD" 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#"${remote}"/}"
    return 0
  fi

  output=$(git remote show "$remote" 2>/dev/null || true)
  while IFS= read -r line; do
    case "$line" in
    *'HEAD branch: '*)
      printf '%s\n' "${line##*HEAD branch: }"
      return 0
      ;;
    esac
  done <<<"$output"

  return 1
}

resolve_pull_request_base_branch() {
  local requested_base_branch="$1"
  local owner="$2"
  local repo_name="$3"
  local remote="$4"
  local base_branch

  if [ -n "$requested_base_branch" ]; then
    printf '%s\n' "$requested_base_branch"
    return 0
  fi

  base_branch=$(default_branch_from_git_api "$owner" "$repo_name" || true)
  if [ -n "$base_branch" ]; then
    printf '%s\n' "$base_branch"
    return 0
  fi

  base_branch=$(default_branch_from_git "$remote" || true)
  if [ -n "$base_branch" ]; then
    printf '%s\n' "$base_branch"
    return 0
  fi

  echo 'Error: unable to determine the pull request base branch' >&2
  return 1
}

resolve_pull_request_context() {
  local branch="$1"
  local requested_base_branch="$2"
  local context_var_name="$3"
  local remote fetch_url push_url repo push_repo owner name head_owner base_branch head_ref existing_pr_response
  local -n context_ref="$context_var_name"

  remote=$(resolve_effective_push_remote "$branch") || return 1
  fetch_url=$(git_remote_fetch_url "$remote") || return 1
  push_url=$(git_remote_push_url "$remote") || return 1
  repo=$(github_repo_from_remote_url "$fetch_url") || return 1
  push_repo=$(github_repo_from_remote_url_optional "$push_url")
  owner=${repo%%/*}
  name=${repo#*/}
  if [ -n "$push_repo" ]; then
    head_owner=${push_repo%%/*}
  else
    head_owner="$owner"
  fi
  head_ref=$(pull_request_head_ref "$owner" "$head_owner" "$branch")
  base_branch=$(resolve_pull_request_base_branch "$requested_base_branch" "$owner" "$name" "$remote") || return 1

  if [ "$branch" = "$base_branch" ]; then
    echo "Error: --pr requires a branch different from the base branch '$base_branch'" >&2
    return 1
  fi

  find_existing_pull_request_response existing_pr_response "$owner" "$name" "$head_owner" "$branch" "$base_branch" || return 1
  context_ref[remote]="$remote"
  context_ref[fetch_url]="$fetch_url"
  context_ref[push_url]="$push_url"
  context_ref[owner]="$owner"
  context_ref[name]="$name"
  context_ref[head_owner]="$head_owner"
  context_ref[head_ref]="$head_ref"
  context_ref[base_branch]="$base_branch"
  # shellcheck disable=SC2154
  {
    context_ref[existing_response]="$existing_pr_response"
    context_ref[existing_url]="$(pull_request_url_from_list_response "$existing_pr_response")"
    context_ref[existing_number]="$(pull_request_number_from_list_response "$existing_pr_response")"
    context_ref[existing_title]="$(pull_request_title_from_list_response "$existing_pr_response")"
    context_ref[existing_body]="$(pull_request_body_from_list_response "$existing_pr_response")"
  }
  if [ -n "$existing_pr_response" ]; then
    # shellcheck disable=SC2154
    context_ref[existing_exists]='true'
  else
    # shellcheck disable=SC2034
    context_ref[existing_exists]='false'
  fi
}
