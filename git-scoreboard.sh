#!/usr/bin/env bash
# Git Scoreboard - Weekly contributor leaderboard for GitHub repos
#
# Score = PRs×10 + small×5 + reviews×8 + fast×5 + deep×3 - mega×5 - driveby×2 - stale×3
#
# Metrics:
#   PRs      = merged PRs authored
#   small    = PRs with < 100 lines changed (bonus)
#   mega     = PRs with > 500 lines changed (penalty)
#   reviews  = code reviews submitted (APPROVED or CHANGES_REQUESTED)
#   fast     = PRs merged within 24 hours (bonus)
#   stale    = PRs that took > 5 days to merge (penalty)
#   deep     = reviews with substantial comments > 50 chars (bonus)
#   driveby  = approvals with empty body (penalty)
#
# Usage:
#   git-scoreboard                         # Current repo, last 7 days
#   git-scoreboard 14                      # Current repo, last 14 days
#   git-scoreboard 7 owner/repo            # Specific repo
#   git-scoreboard 7 owner/repo1 owner/repo2  # Multiple repos
#
# Auto-detection (when no repos specified):
#   - If in a repo with git submodules, scans all submodules
#   - Otherwise, uses the current repo's GitHub remote

set -euo pipefail

DAYS="${1:-7}"
shift 2>/dev/null || true

# --- Determine which repos to scan ---
if [ $# -gt 0 ]; then
    # Repos passed as arguments
    REPOS="$*"
else
    # Auto-detect from current git repo
    REPOS=""

    # Check for git submodules first
    if [ -f .gitmodules ]; then
        while IFS= read -r subdir; do
            REMOTE=$(git -C "$subdir" remote get-url origin 2>/dev/null || true)
            if [ -n "$REMOTE" ]; then
                # Extract owner/repo from git remote URL
                SLUG=$(echo "$REMOTE" | sed -E 's#.*github\.com[:/](.+)(\.git)?$#\1#' | sed 's/\.git$//')
                REPOS="${REPOS:+$REPOS }$SLUG"
            fi
        done < <(git config --file .gitmodules --get-regexp 'submodule\..*\.path' | awk '{print $2}')
    fi

    # If no submodules found, use current repo
    if [ -z "$REPOS" ]; then
        REMOTE=$(git remote get-url origin 2>/dev/null || true)
        if [ -z "$REMOTE" ]; then
            echo "Error: Not in a git repo with a GitHub remote. Pass repos as arguments." >&2
            echo "Usage: git-scoreboard [days] [owner/repo ...]" >&2
            exit 1
        fi
        REPOS=$(echo "$REMOTE" | sed -E 's#.*github\.com[:/](.+)(\.git)?$#\1#' | sed 's/\.git$//')
    fi
fi

echo "Scanning: $REPOS" >&2

# Calculate since date (macOS and Linux compatible)
if date -v-1d >/dev/null 2>&1; then
    SINCE=$(date -v-${DAYS}d '+%Y-%m-%dT00:00:00Z')
    DATE_START=$(date -v-${DAYS}d '+%b %d')
    DATE_END=$(date '+%b %d')
else
    SINCE=$(date -d "${DAYS} days ago" '+%Y-%m-%dT00:00:00Z')
    DATE_START=$(date -d "${DAYS} days ago" '+%b %d')
    DATE_END=$(date '+%b %d')
fi

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# --- Collect all merged PRs across repos ---
echo '[]' > "$TMPDIR/all_prs.json"
for REPO in $REPOS; do
    echo "Fetching PRs from $REPO..." >&2
    RAW=$(gh pr list --repo "$REPO" --state merged \
        --json number,author,additions,deletions,mergedAt,createdAt \
        --limit 200 2>/dev/null || echo '[]')
    FILTERED=$(echo "$RAW" | jq --arg since "$SINCE" --arg repo "$REPO" \
        '[.[] | select(.mergedAt >= $since) | select(.author.is_bot == false) | . + {repo: $repo}]')
    jq -s '.[0] + .[1]' "$TMPDIR/all_prs.json" <(echo "$FILTERED") > "$TMPDIR/tmp.json"
    mv "$TMPDIR/tmp.json" "$TMPDIR/all_prs.json"
done

TOTAL_PRS=$(jq length "$TMPDIR/all_prs.json")
echo "" >&2
echo "Total merged PRs (non-bot): $TOTAL_PRS" >&2

# --- Collect all reviews for these PRs ---
echo '[]' > "$TMPDIR/all_reviews.json"
jq -c '.[] | {repo, number}' "$TMPDIR/all_prs.json" | while IFS= read -r line; do
    REPO=$(echo "$line" | jq -r '.repo')
    NUM=$(echo "$line" | jq -r '.number')
    REVIEWS=$(gh api "repos/$REPO/pulls/$NUM/reviews" 2>/dev/null || echo '[]')
    ENRICHED=$(echo "$REVIEWS" | jq --arg repo "$REPO" --argjson num "$NUM" \
        '[.[] | {user: .user.login, state: .state, body: .body, repo: $repo, pr_number: $num}]')
    jq -s '.[0] + .[1]' "$TMPDIR/all_reviews.json" <(echo "$ENRICHED") > "$TMPDIR/tmp.json"
    mv "$TMPDIR/tmp.json" "$TMPDIR/all_reviews.json"
done

TOTAL_REVIEWS=$(jq length "$TMPDIR/all_reviews.json")
echo "Total reviews: $TOTAL_REVIEWS" >&2
echo "" >&2

# --- Get all unique human users ---
ALL_USERS=$(jq -r '
    [.[].author.login] +
    (input | [.[] | select(.user != null) | .user])
    | unique | .[]
' "$TMPDIR/all_prs.json" "$TMPDIR/all_reviews.json" | grep -v '^$' | grep -v 'null' | grep -v 'app/')

# --- Calculate per-user scores ---
echo '[]' > "$TMPDIR/results.json"

for USER in $ALL_USERS; do
    STATS=$(jq --arg u "$USER" '
    {
        prs: [.[] | select(.author.login == $u)] | length,
        small: [.[] | select(.author.login == $u) | select((.additions + .deletions) < 100)] | length,
        mega: [.[] | select(.author.login == $u) | select((.additions + .deletions) > 500)] | length,
        fast: [.[] | select(.author.login == $u) |
            select(
                ((.mergedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) -
                 (.createdAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) < 86400
            )] | length,
        stale: [.[] | select(.author.login == $u) |
            select(
                ((.mergedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) -
                 (.createdAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) > 432000
            )] | length,
        avg_merge_hours: (
            [.[] | select(.author.login == $u) |
                ((.mergedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) -
                 (.createdAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) / 3600
            ] | if length > 0 then (add / length * 10 | round / 10) else 0 end
        )
    }' "$TMPDIR/all_prs.json")

    REVIEW_STATS=$(jq --arg u "$USER" '
    {
        reviews: [.[] | select(.user == $u) | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")] | length,
        driveby: [.[] | select(.user == $u) | select(.state == "APPROVED") | select(.body == "" or .body == null)] | length,
        deep: [.[] | select(.user == $u) | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") | select((.body | length) > 50)] | length,
        avg_comments: (
            [.[] | select(.user == $u) | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") | (.body | length)]
            | if length > 0 then (add / length * 10 | round / 10) else 0 end
        )
    }' "$TMPDIR/all_reviews.json")

    RESULT=$(echo "$STATS" | jq --arg u "$USER" --argjson rs "$REVIEW_STATS" '
        . + $rs + {user: $u} |
        .score = (.prs * 10 + .small * 5 + .reviews * 8 + .fast * 5 + .deep * 3 - .mega * 5 - .driveby * 2 - .stale * 3)
    ')

    jq -s '.[0] + [.[1]]' "$TMPDIR/results.json" <(echo "$RESULT") > "$TMPDIR/tmp.json"
    mv "$TMPDIR/tmp.json" "$TMPDIR/results.json"
done

# --- Determine display label ---
REPO_COUNT=$(echo "$REPOS" | wc -w | tr -d ' ')
if [ "$REPO_COUNT" -eq 1 ]; then
    LABEL="$REPOS"
else
    # Use the common org prefix if all repos share one
    ORG=$(echo "$REPOS" | tr ' ' '\n' | sed 's#/.*##' | sort -u)
    ORG_COUNT=$(echo "$ORG" | wc -l | tr -d ' ')
    if [ "$ORG_COUNT" -eq 1 ]; then
        LABEL="$ORG ($REPO_COUNT repos)"
    else
        LABEL="$REPO_COUNT repos"
    fi
fi

# --- Output the scoreboard ---
echo ""
echo "================================================"
echo "  📊 GIT SCOREBOARD"
echo "  $LABEL  •  $DATE_START - $DATE_END"
echo "================================================"
echo ""

jq -r '
sort_by(-.score) | to_entries[] |
select(.value.score > 0) |
"\(.key + 1)\t@\(.value.user)\t\(.value.score)\t\(.value.prs)\t\(.value.reviews)\t\(.value.small)\t\(.value.mega)\t\(.value.fast)\t\(.value.stale)\t\(.value.driveby)\t\(.value.deep)\t\(.value.avg_merge_hours)"
' "$TMPDIR/results.json" | (
    printf "%-4s %-25s %6s %5s %7s %6s %5s %5s %6s %8s %5s %9s\n" \
        "#" "User" "Score" "PRs" "Reviews" "Small" "Mega" "Fast" "Stale" "Driveby" "Deep" "AvgMerge"
    printf "%-4s %-25s %6s %5s %7s %6s %5s %5s %6s %8s %5s %9s\n" \
        "---" "-------------------------" "------" "-----" "-------" "------" "-----" "-----" "------" "--------" "-----" "---------"
    RANK=0
    while IFS=$'\t' read -r _ USER SCORE PRS REVIEWS SMALL MEGA FAST STALE DRIVEBY DEEP AVG_MERGE; do
        RANK=$((RANK + 1))
        case $RANK in
            1) MEDAL="🥇  ";;
            2) MEDAL="🥈  ";;
            3) MEDAL="🥉  ";;
            *) MEDAL=$(printf "%-4s" "$RANK");;
        esac
        printf "%s%-25s %6s %5s %7s %6s %5s %5s %6s %8s %5s %8sh\n" \
            "$MEDAL" "$USER" "$SCORE" "$PRS" "$REVIEWS" "$SMALL" "$MEGA" "$FAST" "$STALE" "$DRIVEBY" "$DEEP" "$AVG_MERGE"
    done
)

echo ""
echo "Score = PRs×10 + small×5 + reviews×8 + fast×5 + deep×3 - mega×5 - driveby×2 - stale×3"
echo ""

# --- Awards ---
echo "--- Awards ---"

# Speed Demon: fastest avg merge (min 2 PRs)
jq -r '
    [.[] | select(.prs >= 2)] | sort_by(.avg_merge_hours) | .[0] |
    "🏎️  Speed Demon: @\(.user) (\(.avg_merge_hours)h avg merge)"
' "$TMPDIR/results.json" 2>/dev/null || true

# Deep Diver: highest avg review comment length (min 2 reviews)
jq -r '
    [.[] | select(.reviews >= 2)] | sort_by(-.avg_comments) | .[0] |
    "🤿 Deep Diver: @\(.user) (\(.avg_comments) avg comment length)"
' "$TMPDIR/results.json" 2>/dev/null || true

# Needs Love: longest avg wait for PR merge (min 1 PR)
jq -r '
    [.[] | select(.prs >= 1)] | sort_by(-.avg_merge_hours) | .[0] |
    "😭 Needs Love: @\(.user) (\(.avg_merge_hours)h avg wait)"
' "$TMPDIR/results.json" 2>/dev/null || true

echo ""
echo "--- Metric Definitions ---"
echo "  PRs      Merged pull requests authored"
echo "  Small    PRs with < 100 lines changed (+5 bonus)"
echo "  Mega     PRs with > 500 lines changed (-5 penalty)"
echo "  Reviews  Code reviews submitted (approved or changes requested)"
echo "  Fast     PRs merged within 24 hours (+5 bonus)"
echo "  Stale    PRs that took > 5 days to merge (-3 penalty)"
echo "  Deep     Reviews with comments > 50 chars (+3 bonus)"
echo "  Driveby  Approvals with empty comment body (-2 penalty)"
echo "  AvgMerge Average time from PR creation to merge"
