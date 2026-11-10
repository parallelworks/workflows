The scripts scripts/scheduler.sh and scripts/executor.sh automatically change the following paramerers
in the scheduler and executor properties files. You may change the rest directly on the file. Also,
you may comment any parameter out and it will remain commented.

Executor:
GTDistributed.work-dir
GTDistributed.license-file
GTDistributed.client.hostname
GTDistributed.executor.core-count
GTDistributed.executor.priority

Scheduler:
GTDistributed.work-dir
GTDistributed.job-summary-service-enable (Not available in v2018 and older)