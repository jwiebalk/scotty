#!/usr/bin/env bash
#
# Move all repositories from one organization to another and replicate
# the teams.
#
# Usage:
#   org-transfer-all-repos.sh [OPTIONS] <source org> <target org>
#
# Options:
#   --i-know-what-im-doing Suppress any warning (useful for scripting!)
#   -n                     Dry-run; only show what would be done.
#   -h, --help             Display this message.
#
# Example:
#   org-transfer-all-repos.sh org1 org2
#

BASE_DIR=$(cd "${0%/*}/.." && pwd)
. "$BASE_DIR/lib-ghe.sh"

while [ $# -gt 0 ]; do
    case $1 in
        (--i-know-what-im-doing) NO_WARNING=1; shift;;
        (-n) DRY_RUN=1; shift;;
        (-h|--help) usage 2>&1;;
        (--) shift; break;;
        (-*) usage "$1: unknown option";;
        (*) break;;
    esac
done

SOURCE_ORG=$1
if [ -z "$SOURCE_ORG" ]; then
    usage "Source org is a required parameter!"
fi

TARGET_ORG=$2
if [ -z "$TARGET_ORG" ]; then
    usage "Target org is a required parameter!"
fi

[ -n "$NO_WARNING" ] || warning "This script moves all repos from '$SOURCE_ORG' to '$TARGET_ORG' on $GHE_HOST!"

execute << EOF
    github-env bin/runner -e production "'
        staff_user = User.find_by_login(\"$GHE_USER\");
        target_org = User.find_by_login(\"$TARGET_ORG\");
        source_org = User.find_by_login(\"$SOURCE_ORG\");
        if source_org and target_org and staff_user;
            source_org.repositories.each {|repo|
                repo.teams.each {|source_team|
                    if target_org.teams.find {|t| t.name == source_team.name };
                        raise \"Error: Team #{source_team.name} already exists in #{target_org.login}!\"
                    end;
                }
            }
            GitHub.context.push(actor_id: staff_user.id);
            source_org.repositories.each {|repo|
                if repo.method(:async_transfer_ownership_to).parameters != [[:req, :user], [:keyreq, :actor], [:key, :target_teams], [:key, :notify_target]];
                    raise \"Error: 'Repository#async_transfer_ownership_to' signature changed. GitHub Enterprise version is not compatible!\"
                end;
                teams = repo.teams.map { |t| {
                    \"name\" => t.name,
                    \"description\" => t.description,
                    \"permission\" => t.permission_for(repo),
                    \"privacy\" => t.privacy,
                    \"members\" => t.members.map { |m| m.login },
                    \"maintainers\" => t.maintainers.map { |m| m.login }
                } };
                puts \"Transferring repo: #{repo.name}\";
                repo.async_transfer_ownership_to(target_org, actor: staff_user, target_teams: []);
                target_repo = nil;
                loop do
                    target_repo = Repository.with_name_with_owner(\"#{target_org.login}/#{repo.name}\");
                    break if target_repo;
                    sleep(1);
                end;
                teams.each {|source_team|
                    target_org.reload();
                    target_team = target_org.teams.find {|t| t.name == source_team[\"name\"] };
                    if !target_team;
                        puts \"Creating team: #{source_team[\"name\"]}\";
                        if target_org.method(:create_team).parameters != [[:keyreq, :creator], [:key, :repos], [:key, :ldap_dn], [:key, :maintainers], [:key, :attrs]];
                            raise \"Error: Organization#create_team signature changed. GitHub Enterprise version is not compatible!\"
                        end;
                        target_team = target_org.create_team(creator: staff_user, attrs: { :name => source_team[\"name\"] });
                        target_team.description = source_team[\"description\"];
                        target_team.privacy = source_team[\"privacy\"];
                        target_team.save!;
                        source_team[\"members\"].each {|m|
                            puts \"Adding member to team _#{target_team.name}_: #{m}\";
                            if target_team.method(:add_member).parameters != [[:req, :user], [:opt, :options]];
                                raise \"Error: 'team.add_member' signature changed. GitHub Enterprise version is not compatible!\"
                            end;
                            target_team.add_member(User.find_by_login(m));
                        };
                        source_team[\"maintainers\"].each {|m|
                            puts \"Promote maintainers in team _#{target_team.name}_: #{m}\";
                            if target_team.method(:promote_maintainer).parameters != [[:req, :user]];
                                raise \"Error: Team(Team::Roles)#promote_maintainer signature changed. GitHub Enterprise version is not compatible!\"
                            end;
                            target_team.promote_maintainer(User.find_by_login(m));
                        };
                    end
                    puts \"Adding repo to team _#{target_team.name}_: #{target_repo.name} (#{source_team[\"permission\"]})\";
                    if target_team.method(:add_repository).parameters != [[:req, :repo], [:req, :perm], [:key, :allow_different_owner]];
                        raise \"Error: Team#add_repository signature changed. GitHub Enterprise version is not compatible!\"
                    end;
                    target_team.add_repository(target_repo, source_team[\"permission\"]);
                }
            }
        else
            puts \"ERROR: Source org, target org, or staff user does not exist.\";
        end;
    '"
EOF
