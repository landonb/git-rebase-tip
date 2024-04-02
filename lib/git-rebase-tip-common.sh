#!/usr/bin/env sh
# vim:tw=0:ts=2:sw=2:et:norl:nospell:ft=bash
# Author: Landon Bouma (landonb &#x40; retrosoft &#x2E; com)
# Project: https://github.com/landonb/git-rebase-tip#💁
# License: MIT

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
  local suffix="$2"

  if [ -z "${vers}" ]; then
    # Assumes caller used git_largest_version_tag.
    >&2 warn "No version tag found: Skipping TIP version tag"

    return 0
  fi

  local commit_distances=""
  commit_distances="$(print_commit_distances "${vers}")"

  local tip_vers="${vers}-TIP+${commit_distances}${suffix}"

  # Remove the upstream version tag temporarily, otherwise git-bump
  # refuses to apply it. That's ∵ tip_vers is a pre-release version,
  # ∴ tip_vers < curs_vers, but tip_vers^{commit} > vers^{commit},
  # which is a violation.
  local remote_vers_object
  remote_vers_object="$(git rev-parse refs/tags/${vers})"
  git tag -d "${vers}" > /dev/null

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

  # Restore upstream tag.
  git tag "${vers}" "${remote_vers_object}"

  if ${bump_failed}; then
    >&2 warn "ERROR: Failed: git bump-version-tag \"${tip_vers}\" -- \"-\""

    # For the stderr.
    git bump-version-tag "${tip_vers}" -- "-"

    exit_1
  fi

  printf "%s" "${tip_vers}"
}

# ***

# WRONG/2024-04-02: Alpha compare happens on front matter first, then the
# final number, so the front matter shouldn't change, because it's compared
# lexigraphically. So '1.2.3-9-15+30' changing to '1.2.3-10-15+31' because
# upstream added a commit would still pick '1.2.3-9-15+30' as the largest.
#
#   print_commit_distances () {
#     local vers="$1"
#     local remote_ref="$2"
#
#     local commit_distances=""
#     local dist_sep="-"
#     local final_sep="+"
#     # See also `git bump -c` which outputs HEAD distance, e.g., "6.1.0 (at HEAD~17)"
#     local dist_remote_tag_to_scoped_head
#     # Send remote_ref to avoid stderr complaint if remote branch and local
#     # branch named differently. And specify vers lest current version used.
#     dist_remote_tag_to_scoped_head="$( \
#       git bump-version-tag --distance ${vers} -- ${remote_ref}
#     )"
#
#     commit_distances="${dist_sep}${dist_remote_tag_to_scoped_head}"
#
#     local dist_remote_tag_to_remote_ref
#     dist_remote_tag_to_remote_ref=$(git rev-list --count "refs/tags/${vers}..${remote_ref}")
#     if [ ${dist_remote_tag_to_remote_ref} -ne 0 ]; then
#       local dist_remote_ref_to_scoped_head
#       dist_remote_ref_to_scoped_head=$((${dist_remote_tag_to_scoped_head} - ${dist_remote_tag_to_remote_ref}))
#       commit_distances="${dist_sep}${dist_remote_tag_to_remote_ref}${dist_sep}${dist_remote_ref_to_scoped_head}"
#     fi
#
#     # So that at least our alpha versions are ordered (even though they're
#     # less than the upstream version but are applied to commits after it),
#     # append the total commit count.
#     # - Note this total is dist_remote_tag_to_scoped_head
#     #                    + dist_remote_tag_to_remote_ref
#     #                    + # scoped commits.
#     local dist_remote_tag_to_HEAD
#     dist_remote_tag_to_HEAD=$(git rev-list --count "refs/tags/${vers}..HEAD")
#
#     # The final strings could be, e.g., "-10-15+30", meaning there are 10
#     # upstream commits since the last version, 15 new commits added by the
#     # TIP, and (30 - 10 - 15 =) 5 scoped (PRIVATE/PROTECTED) commits.
#     # - Therefore whenever a commit is added anywhere, the final number
#     #   advances.
#     # WRONG: But as noted above, this strategy isn't not properly sortable.
#     commit_distances="${commit_distances}${final_sep}${dist_remote_tag_to_HEAD}"
#
#     printf "%s" "${commit_distances}"
#   }

print_commit_distances () {
  local vers="$1"

  local dist_remote_tag_to_HEAD
  dist_remote_tag_to_HEAD=$(git rev-list --count "refs/tags/${vers}..HEAD")

  printf "%s" "${dist_remote_tag_to_HEAD}"
}

# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ #

