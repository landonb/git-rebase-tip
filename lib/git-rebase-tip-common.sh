#!/usr/bin/env sh
# vim:tw=0:ts=2:sw=2:et:norl:nospell:ft=bash
# Author: Landon Bouma (landonb &#x40; retrosoft &#x2E; com)
# Project: https://github.com/landonb/git-rebase-tip#💁
# License: MIT

# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ #

_grtcommon_source_deps () {
  # Ensure coreutils installed.
  insist_cmd "realpath" '- TIP: `apt install coreutils` or `brew install coreutils`' \
    || return 1

  # Load the logger library: https://github.com/landonb/sh-logger#🎮🐸
  # - Includes print commands: info, warn, error, debug.
  source_lib "${SHOILERPLATE:-${HOME}/.kit/sh}" "sh-logger/bin/logger.sh" \
    || return 1

  LOG_LEVEL=${TIP_LOG_LEVEL:-${LOG_LEVEL_DEBUG}}
  # So that rebase-todo background exec logger output is colorful.
  SHCOLORS_OFF=false

  # Load Git function lib: https://github.com/landonb/sh-git-nubs#🌰
  # - Includes git_branch_exists, git_branch_name, git_sha_shorten,
  #   git_remote_branch_object_name, git_upstream_parse_branch_name, etc.
  source_lib "${SHOILERPLATE:-${HOME}/.kit/sh}" "sh-git-nubs/lib/git-nubs.sh" \
    || return 1
}

# ***

insist_cmd () {
  local cmd_name="$1"
  local install_hint="$2"

  command -v "${cmd_name}" > /dev/null && return || true

  local logger=echo
  if command -v error > /dev/null; then
    logger=error
  fi

  >&2 ${logger} "ERROR: Missing system command ‘${cmd_name}’."
  if [ -n "${install_hint}" ]; then
    >&2 ${logger} "${install_hint}"
  fi

  return 1
}

# ***

# USYNC: Same source_lib in all the files.
# - SAVVY: The callers have their own source_lib functions, so this
#   copy not needed if running one of the bin/ scripts. But this fcn.
#   is needed if you just want to source this file for development.
source_lib () {
  # For DepoXy users, the project parent directory.
  local depoxy_basedir="$1"
  # As fallback, check deps/ which ships with this project.
  local deps_lib_path="$2"

  local lib_name
  lib_name="$(basename -- "${deps_lib_path}")"

  if command -v "${lib_name}" > /dev/null && . "${lib_name}" \
    || . "${depoxy_basedir}/${deps_lib_path}" 2> /dev/null \
    || . "$(dirname -- "$(realpath -- "$0")")/../${deps_lib_path}" \
  ; then
    return 0
  fi
  
  >&2 echo "ERROR: Cannot determine source path for dependency: ${lib_name}"

  return 1
}

# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ #

insist_git_rev_parse () {
  local git_ref="$1"
  local var_name="$2"

  if ! git rev-parse "${git_ref}" 2> /dev/null; then
    >&2 error "ERROR: Please specify a valid '${var_name}', not: ${git_ref}"

    exit_1
  fi
}

# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ #

git_largest_version_tag_excluding_tip () {
  local upstream="$1"

  local remote_name
  remote_name="$(extract_validated_remote_name "${upstream}")"

  local vers=""
  if [ -n "${remote_name}" ]; then
    # We use ls-remote to check remote tags, but fetch to ensure they
    # exist locally, too.
    git fetch --prune "${remote_name}"
    # git_largest_version_tag returns larest tag remote or local.
    # - We prefer to only consider remote version tags.
    vers="$(git_largest_version_tag_from_remote "${remote_name}")"
    if [ -z "${vers}" ]; then
      >&2 warn "ALERT: The upstream remote has no version tags"
    fi
  fi

  if [ -z "${vers}" ]; then
    # The upstream gitref is not a remote/branch, or at least not
    # its refs/remotes/<remote>/<branch> name.
    # - So look locally, but restrict to those versions on the
    #   upstream commit itself, or on an ancestor of it.
    vers="$(git_largest_version_tag --merged "${upstream}")"
  fi

  printf "%s" "${vers}"
}

extract_validated_remote_name () {
  local upstream="$1"

  local remote_name
  remote_name="$(git_upstream_parse_remote_name "${upstream}")"

  if git remote get-url "${remote_name}" > /dev/null 2>&1; then
    printf "%s" "${remote_name}"
  fi
}

# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ #

# Note we cannot foreground `mr` from exec command, because it runs
# in the same process as Git, and we want to call sort-by-scope next.
# If foregrounded, Git complains that a rebase is under way, and fails.
# So we'll sleep (let Git cleanup) and run in the background, as a
# separate process.
# - Unfortunately, the UX here is annoying, because essentially it'll
# just spew to the console, then the user's prompt will "disappear"
# (scroll up) until the user hits <Enter>.

GIT_REBASE_TODO_PATH=".git/rebase-merge/git-rebase-todo"

inject_exec_callback () {
  local rebase_cmd="$1"

  insist_environ_non_empty () {
    local environ_name="$1"

    if eval "test -z \"\$${environ_name}\""; then
      error
      error "ERROR: Missing ${environ_name} environ"
      error

      return 1
    fi
  }

  insist_environ_non_empty "TIP_COMMAND_ARGS" \
    || return 1

  if [ -n "${MR_ACTION}" ]; then
    # DepoXy ohmyrepos support.
    insist_environ_non_empty "MR_REPO" \
      || return 1

    echo "exec sleep 0.1 && \
      mr -d \"${MR_REPO}\" -n \"${MR_ACTION}\" \"${rebase_cmd}\" \
        ${TIP_COMMAND_ARGS} &" \
        >> "${GIT_REBASE_TODO_PATH}"
  else
    # BWARE: This exec won't work unless:
    # - There are no spaces in any of the arguments.
    # - No non-empty arguments follows an empty ("") argument.

    echo "exec sleep 0.1 && \
      exec sh -c 'TIP_REBASE_CMD=\"${rebase_cmd}\" \"$0\" ${TIP_COMMAND_ARGS} &'" \
        >> "${GIT_REBASE_TODO_PATH}"
  fi

  # debug rebase-todo: $(cat "${GIT_REBASE_TODO_PATH}" | tail -n 1)
}

# ***

log_please_resolve_conflicts_message () {
  info "Please resolve conflicts. We'll resume"
  info "after the final \`git rebase --continue\`"
}

# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ #

manage_tip_version_tag () {
  local vers="$1"
  local stage="$2"

  if [ -z "${vers}" ]; then
    # Assumes caller used git_largest_version_tag.
    >&2 warn "No version tag found: Skipping TIP version tag"

    return 0
  fi

  local next_vers
  if ! next_vers="$( \
    git bump-version-tag p --check -- "-" 2> /dev/null
  )"; then
    >&2 echo "ERROR: Failed: git-bump -p --check -- -"

    # This should errexit.
    git bump-version-tag p --check -- "-"

    exit_1
  fi
  
  local commit_dist=""
  commit_dist="$(print_distance_to_scoped_head "${vers}")"

  local dash_prerelease="-"
  local dot_identifier="."
  if [ -f "$(git_project_root)/pyproject.toml" ]; then
    # PEP440
    dash_prerelease=""
    dot_identifier=""
  fi

  local tip_vers="${next_vers}${dash_prerelease}${stage}${dot_identifier}${commit_dist}"

  # If user deleted old TIP branch and is running this command again,
  # ensure old TIP tag doesn't interfere.
  git tag -d "${tip_vers}" > /dev/null 2>&1 || true

  # - BMP_NO_NORMALIZE=true — Because the '+' usage is not SemVer.
  # - BMP_RESTRICT_LOCAL=true — Don't push to the remote
  #   Similarly, specify "-" as the remote/branch.
  export BMP_NO_NORMALIZE=true
  export BMP_RESTRICT_LOCAL=true
  local bump_failed=false
  if ! git bump-version-tag "${tip_vers}" -- "-" > /dev/null 2>&1; then
    bump_failed=true
  fi

  if ${bump_failed}; then
    >&2 warn "ERROR: Failed: git bump-version-tag \"${tip_vers}\" -- \"-\""

    # For the stderr.
    git bump-version-tag "${tip_vers}" -- "-"

    exit_1
  fi

  printf "%s" "${tip_vers}"
}

# ***

print_distance_to_scoped_head () {
  local vers="$1"

  local scoped_head
  scoped_head="$(print_scope_boundary)"
  [ -n "${scoped_head}" ] || scoped_head="HEAD"

  local dist_remote_tag_to_scoped_head
  dist_remote_tag_to_scoped_head=$( \
    git rev-list --count "refs/tags/${vers}..${scoped_head}"
  )

  printf "%s" "${dist_remote_tag_to_scoped_head}"
}

# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ #

check_git_put_wise_and_sort_by_scope_installed () {
  if ! insist_cmd \
    'git-put-wise' \
    '- See: Project: https://github.com/DepoXy/git-put-wise#🥨' \
    2> /dev/null \
  ; then

    return 1
  fi

  # Should be in same bin/ as git-put-wise.
  if ! insist_cmd \
    'git-rebase-sort-by-scope-protected-private' \
    '- See: Project: https://github.com/DepoXy/git-put-wise#🥨' \
    2> /dev/null \
  ; then

    return 1
  fi
}

# ***

cache_scope_boundary () {
  local scope_boundary="$1"
  local scope_boundary="${1:--}"

  info "git put-wise --scope: $(git_sha_shorten "${scope_boundary}" "7")"

  # The scope_boundary is the final arg, while we peel off and replace.
  # - `xargs` echoes without newline by default.
  TIP_COMMAND_ARGS="$( \
    ( echo "${TIP_COMMAND_ARGS}" | tr ' ' '\n' | head -n -1; \
      echo "${scope_boundary}"; \
    ) | xargs
  )"
}

# ***

print_scope_boundary () {
  # Optional deps. Silently returns happily if put-wise absent.
  if ! check_git_put_wise_and_sort_by_scope_installed; then

    return 0
  fi

  scope_boundary="$(LOG_LEVEL= git put-wise --scope)"

  printf "%s" "${scope_boundary}"
}

# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ #

_grtcommon_source_deps

unset -f _grtcommon_source_deps

