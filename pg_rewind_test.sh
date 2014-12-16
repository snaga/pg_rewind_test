#!/bin/sh

PGHOME=/tmp/pgsql
export PGHOME

PATH=${PGHOME}/bin:$PATH
export PATH

function cleanup()
{
    pg_ctl -w -D ${PGHOME}/data2 stop
    pg_ctl -w -D ${PGHOME}/data1 stop
    killall -9 postmaster postgres
    
    rm -rf ${PGHOME}
}

function install()
{
    make install
    pushd contrib
    make
    make install
    popd
}

function create_master()
{
    mkdir -p ${PGHOME}/data1 ${PGHOME}/arch
    initdb -D ${PGHOME}/data1 --data-checksums --no-locale -E UTF-8
    cat <<EOF >> ${PGHOME}/data1/postgresql.conf
wal_level = hot_standby
archive_mode = on
archive_command = 'cp %p ${PGHOME}/arch/%f'
max_wal_senders = 1
hot_standby = on
wal_keep_segments = 3

logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%d.log'
EOF

    cat <<EOF >> ${PGHOME}/data1/pg_hba.conf
local   replication     snaga                                trust
EOF
}

function start_master()
{
    pg_ctl -w -D ${PGHOME}/data1 start -o "-p 5432"
}

function stop_master()
{
    pg_ctl -w -D ${PGHOME}/data1 stop
}

function create_slave()
{
    pg_basebackup -d "dbname=postgres" -p 5432 -U snaga --pgdata ${PGHOME}/data2 --xlog --verbose

    cat <<EOF >> ${PGHOME}/data2/recovery.conf
restore_command = 'cp ${PGHOME}/arch/%f %p'
standby_mode = on
primary_conninfo = 'port=5432 user=snaga'
EOF
}

function start_slave()
{
    pg_ctl -w -D ${PGHOME}/data2 start -o "-p 5433"
}

function xact_on_master()
{
    createdb -p 5432 testdb
    pgbench -i -p 5432 testdb
}

function xact_on_slave()
{
    psql -p 5433 testdb <<EOF
delete from pgbench_accounts;
EOF
}

function check_master_and_slave_xact()
{
    psql -p 5432 testdb <<EOF
\d
select count(*) from pgbench_accounts;
select count(*) from pgbench_branches;
select count(*) from pgbench_history;
select count(*) from pgbench_tellers;
\x
select * from pg_stat_replication;
EOF

    psql -p 5433 testdb <<EOF
\d
select count(*) from pgbench_accounts;
select count(*) from pgbench_branches;
select count(*) from pgbench_history;
select count(*) from pgbench_tellers;
\x
select * from pg_stat_replication;
EOF
}

function kill_master()
{
    echo "*** Killing the master..."
    head -1 ${PGHOME}/data1/postmaster.pid | xargs kill -9
}

function promote_slave_as_new_master()
{
    echo "*** Promoting the slave as a new master..."
    pg_ctl promote -D ${PGHOME}/data2
}

# check several statuses
function check_statuses()
{
    echo "*** Checking status of the (old) master..."
    psql -p 5432 postgres <<EOF
\x
select * from pg_stat_replication;
select pg_current_xlog_location(), pg_xlogfile_name(pg_current_xlog_location());
select pg_last_xlog_receive_location(), pg_last_xlog_replay_location();
EOF

    echo "*** Checking status of the (old) slave..."
    psql -p 5433 postgres <<EOF
\x
select * from pg_stat_replication;
select pg_current_xlog_location(), pg_xlogfile_name(pg_current_xlog_location());
select pg_last_xlog_receive_location(), pg_last_xlog_replay_location();
EOF
}

function compare_database_clusters()
{
    echo "*** Comparing two database clusters..."

    PGDATA1=$1
    PGDATA2=$2

    pushd ${PGHOME}/data1
    find . -type f > /tmp/pgsql/filecmp.txt
    popd

    pushd ${PGHOME}/data2
    find . -type f >> /tmp/pgsql/filecmp.txt
    popd

    sort /tmp/pgsql/filecmp.txt | grep -v postmaster.opts | grep -v postmaster.pid | \
	uniq | awk '{ print "echo " $1 "; cmp -l '${PGHOME}'/data1/" $1 " '${PGHOME}'/data2/" $1 }' | \
	tee > /tmp/pgsql/cmp.sh
    
    sh /tmp/pgsql/cmp.sh
}

cleanup
install

create_master
start_master

create_slave
start_slave

check_statuses

xact_on_master
check_master_and_slave_xact
check_statuses

# must be failed. ok.
xact_on_slave
check_statuses

# starting failover and promoting stuff
kill_master

promote_slave_as_new_master
sleep 5
check_statuses
xact_on_slave

# --------------------------------------------
# re-sync the old master as a new slave.
# --------------------------------------------

# pg_rewind assumes the postmaster previously got clean shutdown,
# and is stopping.
start_master
check_statuses
stop_master

# need to checkpoint on the new master (old slave) to ensure
# that the latest timeline id is in pg_control file on the disk.
psql -p 5433 -c "checkpoint" postgres

pg_rewind --source-pgdata=${PGHOME}/data2 --target-pgdata=${PGHOME}/data1 -v

# compare the result
compare_database_clusters ${PGHOME}/data1 ${PGHOME}/data2
