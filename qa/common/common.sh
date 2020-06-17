#!/bin/bash
#
# This file is part of the sesdev-qa integration test suite
#

set -e

# BASEDIR is set by the calling script
# shellcheck disable=SC1090
# shellcheck disable=SC1091
source "$BASEDIR/common/helper.sh"
# shellcheck disable=SC1090
# shellcheck disable=SC1091
source "$BASEDIR/common/json.sh"
# shellcheck disable=SC1090
# shellcheck disable=SC1091
source "$BASEDIR/common/zypper.sh"
# shellcheck disable=SC1090
# shellcheck disable=SC1091
source "$BASEDIR/common/rgw.sh"


#
# functions that process command-line arguments
#

function assert_enhanced_getopt {
    set +e
    echo -n "Running 'getopt --test'... "
    getopt --test > /dev/null
    if [ $? -ne 4 ]; then
        echo "FAIL"
        echo "This script requires enhanced getopt. Bailing out."
        exit 1
    fi
    echo "PASS"
    set -e
}


#
# functions that print status information
#

function cat_salt_config {
    cat /etc/salt/master
    cat /etc/salt/minion
}

function salt_pillar_items {
    salt '*' pillar.items
}

function salt_pillar_get_roles {
    salt '*' pillar.get roles
}

function salt_cmd_run_lsblk {
    salt '*' cmd.run lsblk
}

function cat_ceph_conf {
    salt '*' cmd.run "cat /etc/ceph/ceph.conf" 2>/dev/null
}

function admin_auth_status {
    ceph auth get client.admin
    ls -l /etc/ceph/ceph.client.admin.keyring
    cat /etc/ceph/ceph.client.admin.keyring
}

function number_of_hosts_in_ceph_osd_tree {
    ceph osd tree -f json-pretty | jq '[.nodes[] | select(.type == "host")] | length'
}

function number_of_osds_in_ceph_osd_tree {
    ceph osd tree -f json-pretty | jq '[.nodes[] | select(.type == "osd")] | length'
}

function ceph_cluster_status {
    ceph pg stat -f json-pretty
    _grace_period 1
    ceph health detail -f json-pretty
    _grace_period 1
    ceph osd tree
    _grace_period 1
    ceph osd pool ls detail -f json-pretty
    _grace_period 1
    ceph -s
}

function ceph_log_grep_enoent_eaccess {
    set +e
    grep -rH "Permission denied" /var/log/ceph
    grep -rH "No such file or directory" /var/log/ceph
    set -e
}


#
# core validation tests
#

function support_cop_out_test {
    set +x
    local supported
    supported="sesdev-qa supports this OS"
    local not_supported
    not_supported="ERROR: sesdev-qa does not currently support this OS"
    echo
    echo "WWWW: support_cop_out_test"
    echo "Detected operating system $NAME $VERSION_ID"
    case "$ID" in
        opensuse*|suse|sles)
            case "$VERSION_ID" in
                15*)
                    echo "$supported"
                    ;;
                *)
                    echo "$not_supported"
                    ;;
            esac
            ;;
        *)
            echo "$not_supported"
            false
            ;;
    esac
    set +x
    echo "WWWW: support_cop_out_test: OK"
    echo
}

function no_non_oss_repos_test {
    local success
    echo
    echo "WWWW: no_non_oss_repos_test"
    echo "Detected operating system $NAME $VERSION_ID"
    echo
    case "$ID" in
        opensuse*|suse|sles)
            if zypper lr -u | grep 'non-oss' ; then
                echo
                echo "ERROR: Non-OSS repo(s) detected!"
            else
                success="not_empty"
            fi
            ;;
        *)
            echo "ERROR: Unsupported OS ->$ID<-"
            ;;
    esac
    if [ "$success" ] ; then
        echo "WWWW: no_non_oss_repos_test: OK"
        echo
    else
        echo "WWWW: no_non_oss_repos_test: FAIL"
        echo
        false
    fi
}

function make_salt_master_an_admin_node_test {
    local arbitrary_mon_node
    echo
    echo "WWWW: make_salt_master_an_admin_node_test"
    _zypper_install_on_master ceph-common
    mkdir -p "/etc/ceph"
    if [ -f "$ADMIN_KEYRING" ] || [ -f "$CEPH_CONF" ] ; then
        true
    else
        set -x
        arbitrary_mon_node="$(_first_x_node mon)"
        if [ ! -f "$ADMIN_KEYRING" ] ; then
            _copy_file_from_minion_to_master "$arbitrary_mon_node" "$ADMIN_KEYRING"
            chmod 0600 "$ADMIN_KEYRING"
        fi
        if [ ! -f "$CEPH_CONF" ] ; then
            _copy_file_from_minion_to_master "$arbitrary_mon_node" "$CEPH_CONF"
        fi
        set +x
    fi
    set -x
    test -f "$ADMIN_KEYRING"
    test -f "$CEPH_CONF"
    set +x
    echo "WWWW: make_salt_master_an_admin_node_test: OK"
    echo
}

function ceph_rpm_version_test {
# test that ceph RPM version matches "ceph --version"
# for a loose definition of "matches"
    echo
    echo "WWWW: ceph_rpm_version_test"
    set -x
    rpm -q ceph-common
    set +x
    local rpm_name
    rpm_name="$(rpm -q ceph-common)"
    local rpm_ceph_version
    rpm_ceph_version="$(perl -e '"'"$rpm_name"'" =~ m/ceph-common-(\d+\.\d+\.\d+)/; print "$1\n";')"
    echo "According to RPM, the ceph upstream version is ->$rpm_ceph_version<-"
    test -n "$rpm_ceph_version"
    set -x
    ceph --version
    set +x
    local buffer
    buffer="$(ceph --version)"
    local ceph_ceph_version
    ceph_ceph_version="$(perl -e '"'"$buffer"'" =~ m/ceph version (\d+\.\d+\.\d+)/; print "$1\n";')"
    echo "According to \"ceph --version\", the ceph upstream version is ->$ceph_ceph_version<-"
    test -n "$rpm_ceph_version"
    set -x
    test "$rpm_ceph_version" = "$ceph_ceph_version"
    set +x
    echo "WWWW: ceph_rpm_version_test: OK"
    echo
}

function ceph_daemon_versions_test {
    local strict_versions="$1"
    local version_host
    local version_daemon
    echo
    echo "WWWW: ceph_daemon_versions_test"
    set -x
    ceph --version
    ceph versions
    set +x
    version_host="$(_extract_ceph_version "$(ceph --version)")"
    version_daemon="$(_extract_ceph_version "$(ceph versions | jq -r '.overall | keys[]')")"
    if [ "$strict_versions" ] ; then
        set -x
        test "$version_host" = "$version_daemon"
    fi
    set +x
    echo "WWWW: ceph_daemon_versions_test: OK"
    echo
}

function ceph_cluster_running_test {
    echo
    echo "WWWW: ceph_cluster_running_test"
    _ceph_cluster_running
    echo "WWWW: ceph_cluster_running_test: OK"
    echo
}

function maybe_wait_for_osd_nodes_test {
    local expected_osd_nodes="$1"
    echo
    echo "WWWW: maybe_wait_for_osd_nodes_test"
    if [ "$expected_osd_nodes" ] ; then
        local actual_osd_nodes
        local minutes_to_wait
        minutes_to_wait="5"
        local minute
        local i
        local success
        echo "Waiting up to $minutes_to_wait minutes for all $expected_osd_nodes OSD node(s) to show up..."
        for minute in $(seq 1 "$minutes_to_wait") ; do
            for i in $(seq 1 4) ; do
                set -x
                actual_osd_nodes="$(json_osd_nodes)"
                set +x
                if [ "$actual_osd_nodes" = "$expected_osd_nodes" ] ; then
                    success="not_empty"
                    break 2
                else
                    _grace_period 15 "$i"
                fi
            done
            echo "Minutes left to wait: $((minutes_to_wait - minute))"
        done
        if [ "$success" ] ; then
            echo "WWWW: maybe_wait_for_osd_nodes_test: OK"
            echo
        else
            echo "$expected_osd_nodes OSD nodes did not appear even after waiting $minutes_to_wait minutes. Giving up."
            echo "WWWW: maybe_wait_for_osd_nodes_test: FAIL"
            echo
            false
        fi
    else
        echo "No OSD nodes expected: nothing to wait for."
        echo "maybe_wait_for_osd_nodes_test: SKIPPED"
        echo
    fi
}

function maybe_wait_for_mdss_test {
    local expected_mdss="$1"
    echo
    echo "WWWW: maybe_wait_for_mdss_test"
    if [ "$expected_mdss" ] ; then
        local actual_mdss
        local minutes_to_wait
        minutes_to_wait="5"
        local metadata_mdss
        local minute
        local i
        local success
        echo "Waiting up to $minutes_to_wait minutes for all $expected_mdss MDS daemon(s) to show up..."
        for minute in $(seq 1 "$minutes_to_wait") ; do
            for i in $(seq 1 4) ; do
                set -x
                metadata_mdss="$(json_metadata_mdss)"
                actual_mdss="$(json_total_mdss)"
                set +x
                if [ "$actual_mdss" = "$expected_mdss" ] && [ "$actual_mdss" = "$metadata_mdss" ] ; then
                    success="not_empty"
                    break 2
                else
                    _grace_period 15 "$i"
                fi
            done
            echo "Minutes left to wait: $((minutes_to_wait - minute))"
        done
        if [ "$success" ] ; then
            echo "WWWW: maybe_wait_for_mdss_test: OK"
            echo
        else
            echo "$expected_mdss MDS daemons did not appear even after waiting $minutes_to_wait minutes. Giving up."
            echo "WWWW: maybe_wait_for_mdss_test: FAIL"
            echo
            false
        fi
    else
        echo "No MDSs expected: nothing to wait for."
        echo "maybe_wait_for_mdss_test: SKIPPED"
        echo
    fi
}

function maybe_wait_for_rgws_test {
    local expected_rgws="$1"
    echo
    echo "WWWW: maybe_wait_for_rgws_test"
    if [ "$expected_rgws" ] ; then
        local actual_rgws
        local minutes_to_wait
        minutes_to_wait="5"
        local minute
        local i
        local success
        echo "Waiting up to $minutes_to_wait minutes for all $expected_rgws RGW daemon(s) to show up..."
        for minute in $(seq 1 "$minutes_to_wait") ; do
            for i in $(seq 1 4) ; do
                set -x
                actual_rgws="$(json_total_rgws)"
                set +x
                if [ "$actual_rgws" = "$expected_rgws" ] ; then
                    success="not_empty"
                    break 2
                else
                    _grace_period 15 "$i"
                fi
            done
            echo "Minutes left to wait: $((minutes_to_wait - minute))"
        done
        if [ "$success" ] ; then
            echo "WWWW: maybe_wait_for_rgws_test: OK"
            echo
        else
            echo "$expected_rgws RGW daemons did not appear even after waiting $minutes_to_wait minutes. Giving up."
            echo "WWWW: maybe_wait_for_rgws_test: FAIL"
            echo
            false
        fi
    else
        echo "No RGWs expected: nothing to wait for."
        echo "maybe_wait_for_rgws_test: SKIPPED"
        echo
    fi
}

function maybe_wait_for_nfss_test {
    # this function uses json_ses7_orch_{ls,ps}, which only work in
    # {octopus,ses7,pacific}
    if [ "$VERSION_ID" = "15.2" ] ; then
        local expected_nfss="$1"
        echo
        echo "WWWW: maybe_wait_for_nfss_test"
        if [ "$expected_nfss" ] ; then
            local orch_ps_nfss
            local orch_ls_nfss
            local minutes_to_wait
            minutes_to_wait="5"
            local minute
            local i
            local success
            echo "Waiting up to $minutes_to_wait minutes for all $expected_nfss NFS daemon(s) to show up..."
            for minute in $(seq 1 "$minutes_to_wait") ; do
                for i in $(seq 1 4) ; do
                    set -x
                    orch_ls_nfss="$(json_ses7_orch_ls nfs)"
                    orch_ps_nfss="$(json_ses7_orch_ps nfs)"
                    set +x
                    if [ "$orch_ls_nfss" = "$expected_nfss" ] && [ "$orch_ps_nfss" = "$expected_nfss" ] ; then
                        success="not_empty"
                        break 2
                    else
                        _grace_period 15 "$i"
                    fi
                done
                echo "Minutes left to wait: $((minutes_to_wait - minute))"
            done
            if [ "$success" ] ; then
                echo "WWWW: maybe_wait_for_nfss_test: OK"
                echo
            else
                echo "$expected_nfss NFS daemons did not appear even after waiting $minutes_to_wait minutes. Giving up."
                echo "WWWW: maybe_wait_for_nfss_test: FAIL"
                echo
                false
            fi
        else
            echo "No NFSs expected: nothing to wait for."
            echo "WWWW: maybe_wait_for_nfss_test: SKIPPED"
            echo
        fi
    fi
}

function mgr_is_available_test {
    echo
    echo "WWWW: mgr_is_available_test"
    test "$(json_mgr_is_available)"
    echo "WWWW: mgr_is_available_test: OK"
    echo
}

function number_of_daemons_expected_vs_metadata_test {
    # only works for core daemons
    echo
    echo "WWWW: number_of_daemons_expected_vs_metadata_test"
    local metadata_mgrs
    metadata_mgrs="$(json_metadata_mgrs)"
    local metadata_mons
    metadata_mons="$(json_metadata_mons)"
    local metadata_mdss
    metadata_mdss="$(json_metadata_mdss)"
    local metadata_osds
    metadata_osds="$(json_metadata_osds)"
    local success
    success="yes"
    local expected_mgrs
    local expected_mons
    local expected_mdss
    local expected_osds
    [ "$MGR_NODES" ] && expected_mgrs="$MGR_NODES"
    [ "$MON_NODES" ] && expected_mons="$MON_NODES"
    [ "$MDS_NODES" ] && expected_mdss="$MDS_NODES"
    [ "$OSDS" ]      && expected_osds="$OSDS"
    if [ "$expected_mons" ] ; then
        echo "MON daemons (metadata/expected): $metadata_mons/$expected_mons"
        [ "$metadata_mons" = "$expected_mons" ] || success=""
    fi
    if [ "$expected_mgrs" ] ; then
        echo "MGR daemons (metadata/expected): $metadata_mgrs/$expected_mgrs"
        if [ "$metadata_mgrs" = "$expected_mgrs" ] ; then
            true  # normal success case
        elif [ "$expected_mgrs" -gt "1" ] && [ "$metadata_mgrs" = "$((expected_mgrs + 1))" ] ; then
            true  # workaround for https://tracker.ceph.com/issues/45093
        else
            success=""
        fi
    fi
    if [ "$expected_mdss" ] ; then
        echo "MDS daemons (metadata/expected): $metadata_mdss/$expected_mdss"
        [ "$metadata_mdss" = "$expected_mdss" ] || success=""
    fi
    if [ "$expected_osds" ] ; then
        echo "OSD daemons (metadata/expected): $metadata_osds/$expected_osds"
        [ "$metadata_osds" = "$expected_osds" ] || success=""
    fi
    if [ "$success" ] ; then
        echo "WWWW: number_of_daemons_expected_vs_metadata_test: OK"
        echo
    else
        echo "ERROR: Detected disparity between expected number of daemons and cluster metadata!"
        echo "WWWW: number_of_daemons_expected_vs_metadata_test: FAIL"
        echo
        false
    fi
}

function number_of_services_expected_vs_orch_ls_test {
    echo
    echo "WWWW: number_of_services_expected_vs_orch_ls_test"
    if [ "$VERSION_ID" = "15.2" ] ; then
        local orch_ls_mgrs
        orch_ls_mgrs="$(json_ses7_orch_ls mgr)"
        local orch_ls_mons
        orch_ls_mons="$(json_ses7_orch_ls mon)"
        local orch_ls_mdss
        orch_ls_mdss="$(json_ses7_orch_ls mds)"
        ## commented-out osds pending resolution of
        ## - https://bugzilla.suse.com/show_bug.cgi?id=1172791
        ## - https://github.com/SUSE/sesdev/pull/203
        # local orch_ls_osds
        # orch_ls_osds="$(json_ses7_orch_ls osd)"
        local orch_ls_rgws
        orch_ls_rgws="$(json_ses7_orch_ls rgw)"
        local orch_ls_nfss
        orch_ls_nfss="$(json_ses7_orch_ls nfs)"
        local success
        success="yes"
        local expected_mgrs
        local expected_mons
        local expected_mdss
        local expected_osds
        local expected_rgws
        local expected_nfss
        [ "$MGR_NODES" ] && expected_mgrs="$MGR_NODES"
        [ "$MON_NODES" ] && expected_mons="$MON_NODES"
        [ "$MDS_NODES" ] && expected_mdss="$MDS_NODES"
        [ "$OSDS" ]      && expected_osds="$OSDS"
        [ "$RGW_NODES" ] && expected_rgws="$RGW_NODES"
        [ "$NFS_NODES" ] && expected_nfss="$NFS_NODES"
        if [ "$expected_mgrs" ] ; then
            echo "MGR services (orch ls/expected): $orch_ls_mgrs/$expected_mgrs"
            if [ "$orch_ls_mgrs" = "$expected_mgrs" ] ; then
                true  # normal success case
            elif [ "$expected_mgrs" -gt "1" ] && [ "$orch_ls_mgrs" = "$((expected_mgrs + 1))" ] ; then
                true  # workaround for https://tracker.ceph.com/issues/45093
            else
                success=""
            fi
        fi
        if [ "$expected_mons" ] ; then
            echo "MON services (orch ls/expected): $orch_ls_mons/$expected_mons"
            [ "$orch_ls_mons" = "$expected_mons" ] || success=""
        fi
        if [ "$expected_mdss" ] ; then
            echo "MDS services (orch ls/expected): $orch_ls_mdss/$expected_mdss"
            [ "$orch_ls_mdss" = "$expected_mdss" ] || success=""
        fi
        # if [ "$expected_osds" ] ; then
        #     echo "OSDs orch ls/expected: $orch_ls_osds/$expected_osds"
        #     [ "$orch_ls_osds" = "$expected_osds" ] || success=""
        # fi
        if [ "$expected_rgws" ] ; then
            echo "RGW services (orch ls/expected): $orch_ls_rgws/$expected_rgws"
            [ "$orch_ls_rgws" = "$expected_rgws" ] || success=""
        fi
        if [ "$expected_nfss" ] ; then
            echo "NFS services (orch ls/expected): $orch_ls_nfss/$expected_nfss"
            [ "$orch_ls_nfss" = "$expected_nfss" ] || success=""
        fi
        if [ "$success" ] ; then
            echo "WWWW: number_of_services_expected_vs_orch_ls_test: OK"
            echo
        else
            echo "ERROR: Detected disparity between expected number of services and \"ceph orch ls\"!"
            echo "WWWW: number_of_services_expected_vs_orch_ls_test: FAIL"
            echo
            false
        fi
    else
        echo "WWWW: number_of_services_expected_vs_orch_ls_test: SKIPPED"
        echo
    fi
}

function number_of_services_expected_vs_orch_ps_test {
    echo
    echo "WWWW: number_of_services_expected_vs_orch_ps_test"
    if [ "$VERSION_ID" = "15.2" ] ; then
        local orch_ps_mgrs
        orch_ps_mgrs="$(json_ses7_orch_ps mgr)"
        local orch_ps_mons
        orch_ps_mons="$(json_ses7_orch_ps mon)"
        local orch_ps_mdss
        orch_ps_mdss="$(json_ses7_orch_ps mds)"
        ## commented-out osds pending resolution of
        ## - https://bugzilla.suse.com/show_bug.cgi?id=1172791
        ## - https://github.com/SUSE/sesdev/pull/203
        # local orch_ps_osds
        # orch_ps_osds="$(json_ses7_orch_ps osd)"
        local orch_ps_rgws
        orch_ps_rgws="$(json_ses7_orch_ps rgw)"
        local orch_ps_nfss
        orch_ps_nfss="$(json_ses7_orch_ps nfs)"
        local success
        success="yes"
        local expected_mgrs
        local expected_mons
        local expected_mdss
        local expected_osds
        local expected_rgws
        local expected_nfss
        [ "$MGR_NODES" ] && expected_mgrs="$MGR_NODES"
        [ "$MON_NODES" ] && expected_mons="$MON_NODES"
        [ "$MDS_NODES" ] && expected_mdss="$MDS_NODES"
        [ "$OSDS" ]      && expected_osds="$OSDS"
        [ "$RGW_NODES" ] && expected_rgws="$RGW_NODES"
        [ "$NFS_NODES" ] && expected_nfss="$NFS_NODES"
        if [ "$expected_mgrs" ] ; then
            echo "MGR daemons (orch ps/expected): $orch_ps_mgrs/$expected_mgrs"
            if [ "$orch_ps_mgrs" = "$expected_mgrs" ] ; then
                true  # normal success case
            elif [ "$expected_mgrs" -gt "1" ] && [ "$orch_ps_mgrs" = "$((expected_mgrs + 1))" ] ; then
                true  # workaround for https://tracker.ceph.com/issues/45093
            else
                success=""
            fi
        fi
        if [ "$expected_mons" ] ; then
            echo "MON daemons (orch ps/expected): $orch_ps_mons/$expected_mons"
            [ "$orch_ps_mons" = "$expected_mons" ] || success=""
        fi
        if [ "$expected_mdss" ] ; then
            echo "MDS daemons (orch ps/expected): $orch_ps_mdss/$expected_mdss"
            [ "$orch_ps_mdss" = "$expected_mdss" ] || success=""
        fi
        # if [ "$expected_osds" ] ; then
        #     echo "OSDs orch ps/expected: $orch_ps_osds/$expected_osds"
        #     [ "$orch_ps_osds" = "$expected_osds" ] || success=""
        # fi
        if [ "$expected_rgws" ] ; then
            echo "RGW daemons (orch ps/expected): $orch_ps_rgws/$expected_rgws"
            [ "$orch_ps_rgws" = "$expected_rgws" ] || success=""
        fi
        if [ "$expected_nfss" ] ; then
            echo "NFS daemons (orch ps/expected): $orch_ps_nfss/$expected_nfss"
            [ "$orch_ps_nfss" = "$expected_nfss" ] || success=""
        fi
        if [ "$success" ] ; then
            echo "WWWW: number_of_services_expected_vs_orch_ps_test: OK"
            echo
        else
            echo "ERROR: Detected disparity between expected number of services and \"ceph orch ps\"!"
            echo "WWWW: number_of_services_expected_vs_orch_ps_test: FAIL"
            echo
            false
        fi
    else
        echo "WWWW: number_of_services_expected_vs_orch_ps_test: SKIPPED"
        echo
    fi
}

function number_of_daemons_expected_vs_actual {
    echo
    echo "WWWW: number_of_nodes_actual_vs_expected_test"
    local actual_total_nodes
    actual_total_nodes="$(json_total_nodes)"
    local actual_mgr_nodes
    actual_mgr_nodes="$(json_total_mgrs)"
    local actual_mon_nodes
    actual_mon_nodes="$(json_total_mons)"
    local actual_mds_nodes
    actual_mds_nodes="$(json_total_mdss)"
    local actual_rgw_nodes
    actual_rgw_nodes="$(json_total_rgws)"
    local actual_osd_nodes
    actual_osd_nodes="$(json_osd_nodes)"
    local actual_osds
    actual_osds="$(json_total_osds)"
    local success
    success="yes"
    local expected_total_nodes
    local expected_mgr_nodes
    local expected_mon_nodes
    local expected_mds_nodes
    local expected_rgw_nodes
    local expected_osd_nodes
    local expected_osds
    [ "$TOTAL_NODES" ] && expected_total_nodes="$TOTAL_NODES"
    [ "$MGR_NODES" ]   && expected_mgr_nodes="$MGR_NODES"
    [ "$MON_NODES" ]   && expected_mon_nodes="$MON_NODES"
    [ "$MDS_NODES" ]   && expected_mds_nodes="$MDS_NODES"
    [ "$RGW_NODES" ]   && expected_rgw_nodes="$RGW_NODES"
    [ "$OSD_NODES" ]   && expected_osd_nodes="$OSD_NODES"
    [ "$OSDS" ]        && expected_osds="$OSDS"
    if [ "$expected_total_nodes" ] ; then
        echo "total nodes (actual/expected):  $actual_total_nodes/$expected_total_nodes"
        [ "$actual_total_nodes" = "$expected_total_nodes" ] || success=""
    fi
    if [ "$expected_mon_nodes" ] ; then
        echo "MON nodes (actual/expected):    $actual_mon_nodes/$expected_mon_nodes"
        [ "$actual_mon_nodes" = "$expected_mon_nodes" ] || success=""
    fi
    if [ "$expected_mgr_nodes" ] ; then
        echo "MGR nodes (actual/expected):    $actual_mgr_nodes/$expected_mgr_nodes"
        if [ "$actual_mgr_nodes" = "$expected_mgr_nodes" ] ; then
            true  # normal success case
        elif [ "$expected_mgr_nodes" -gt "1" ] && [ "$actual_mgr_nodes" = "$((expected_mgr_nodes + 1))" ] ; then
            true  # workaround for https://tracker.ceph.com/issues/45093
        else
            success=""
        fi
    fi
    if [ "$expected_mds_nodes" ] ; then
        echo "MDS nodes (actual/expected):    $actual_mds_nodes/$expected_mds_nodes"
        [ "$actual_mds_nodes" = "$expected_mds_nodes" ] || success=""
    fi
    if [ "$expected_rgw_nodes" ] ; then
        echo "RGW nodes (actual/expected):    $actual_rgw_nodes/$expected_rgw_nodes"
        [ "$actual_rgw_nodes" = "$expected_rgw_nodes" ] || success=""
    fi
    if [ "$expected_osd_nodes" ] ; then
        echo "OSD nodes (actual/expected):    $actual_osd_nodes/$expected_osd_nodes"
        [ "$actual_osd_nodes" = "$expected_osd_nodes" ] || success=""
    fi
    if [ "$expected_osds" ] ; then
        echo "total OSDs (actual/expected):   $actual_osds/$expected_osds"
        [ "$actual_osds" = "$expected_osds" ] || success=""
    fi
    if [ "$success" ] ; then
        echo "WWWW: number_of_nodes_actual_vs_expected_test: OK"
        echo
    else
        echo "ERROR: Detected disparity between expected and actual numbers of nodes/daemons"
        echo "WWWW: number_of_nodes_actual_vs_expected_test: FAIL"
        echo
        false
    fi
}

function ceph_health_test {
# wait for up to some minutes for cluster to reach HEALTH_OK
    echo
    echo "WWWW: ceph_health_test"
    local minutes_to_wait
    minutes_to_wait="5"
    local cluster_status
    local minute
    local i
    for minute in $(seq 1 "$minutes_to_wait") ; do
        for i in $(seq 1 4) ; do
            set -x
            ceph status
            cluster_status="$(ceph health detail --format json | jq -r .status)"
            set +x
            if [ "$cluster_status" = "HEALTH_OK" ] ; then
                break 2
            else
                _grace_period 15 "$i"
            fi
        done
        echo "Minutes left to wait: $((minutes_to_wait - minute))"
    done
    if [ "$cluster_status" = "HEALTH_OK" ] ; then
        echo "WWWW: ceph_health_test: OK"
        echo
    else
        echo "HEALTH_OK not reached even after waiting for $minutes_to_wait minutes"
        echo "WWWW: ceph_health_test: FAIL"
        echo
        false
    fi
}

function maybe_rgw_smoke_test {
# assert that the Object Gateway is alive on the node where it is expected to be
    echo
    echo "WWWW: maybe_rgw_smoke_test"
    if [ "$RGW_NODE_LIST" ] ; then
        install_rgw_test_dependencies
        if [ "$VERSION_ID" = "12.3" ] ; then
            # no "readarray -d" in SLE-12-SP3: use a simpler version of the test
            local rgw_node_name
            rgw_node_name="$(_first_x_node rgw)"
            set -x
            rgw_curl_test "$rgw_node_name"
            set +x
            echo "WWWW: maybe_rgw_smoke_test: OK"
            echo
        else
            local rgw_nodes_arr
            local rgw_node_count
            rgw_node_count="0"
            local rgw_node_under_test
            readarray -d , -t rgw_nodes_arr <<<"$RGW_NODE_LIST"
            for (( n=0; n < ${#rgw_nodes_arr[*]}; n++ )) ; do
                set -x
                rgw_node_under_test="${rgw_nodes_arr[n]}"
                rgw_node_under_test="${rgw_node_under_test//[$'\t\r\n']}"
                rgw_curl_test "$rgw_node_under_test"
                set +x
                rgw_node_count="$((rgw_node_count + 1))"
            done
            echo "RGW nodes expected/tested: $rgw_node_count/${#rgw_nodes_arr[*]}"
            if [ "$rgw_node_count" = "${#rgw_nodes_arr[*]}" ] ; then
                echo "WWWW: maybe_rgw_smoke_test: OK"
                echo
            else
                echo "WWWW: maybe_rgw_smoke_test: FAIL"
                echo
                false
            fi
        fi
    else
        echo "WWWW: maybe_rgw_smoke_test: SKIPPED"
        echo
    fi
}
