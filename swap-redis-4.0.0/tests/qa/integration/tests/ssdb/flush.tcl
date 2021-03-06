# only flush exec on master
if {$::accurate} {
    set allflush {flushdb}
} else {
    set allflush {flushall}
}

start_server {tags {"ssdb"}} {
    test "#issue flush and set cause memory leak" {
        for {set n 0} {$n < 10} {incr n} {
            foreach flush $allflush {
                r set foo bar

                assert_equal {bar} [r get foo]
                r $flush
            }
        }
        assert {[status r used_memory] < 2000000}
    }
}

start_server {tags {"ssdb"}} {
    set master [srv client]
    set master_host [srv host]
    set master_port [srv port]
    start_server {} {
        set slave [srv client]
        foreach flush $allflush {
            test "$flush not break master-slave link after sync done" {
                $master set foo bar
                $slave slaveof $master_host $master_port
                wait_for_condition 50 100 {
                    {bar} == [$slave get foo]
                } else {
                    fail "SET on master did not propagated on slave"
                }
                wait_for_online $master
                $master $flush
                wait_for_condition 30 100 {
                    [$slave debug digest] == 0000000000000000000000000000000000000000
                } else {
                    fail "Digest not null:slave([$slave debug digest]) after too long time."
                }
                wait_for_online $master
                assert_equal 0 [s -1 sync_partial_ok] "no partial sync"
                assert_equal 1 [s -1 sync_full] "only one full sync"
            }
        }
    }
}

start_server {tags {"ssdb"}} {
    set master [srv client]
    set master_host [srv host]
    set master_port [srv port]
    start_server {} {
        set slave [srv client]
        foreach flush $allflush {
            test "$flush ok during sync process" {
                $master set foo bar
                $slave slaveof $master_host $master_port
                wait_for_condition 50 100 {
                    {bar} == [$slave get foo]
                } else {
                    fail "SET on master did not propagated on slave"
                }
                $master $flush
                wait_for_online $master
                wait_for_condition 30 100 {
                    [$slave debug digest] == 0000000000000000000000000000000000000000
                } else {
                    fail "Digest not null:slave([$slave debug digest]) after too long time."
                }
                $master set foo bar
                wait_for_condition 50 100 {
                    {bar} == [$slave get foo]
                } else {
                    fail "SET on master did not propagated on slave after $flush"
                }
            }
        }
    }
}

start_server {tags {"ssdb"}
overrides {maxmemory 0}} {
    foreach flush $allflush {
        test "set key in ssdb and redis" {
            r set foo bar
            r set fooxxx barxxx
            wait_ssdb_reconnect
            dumpto_ssdb_and_wait r fooxxx

            list [r get foo] [sr get fooxxx]
        } {bar barxxx}

        test "$flush command" {
            r $flush
        } {OK}

        test "$flush key in ssdb and redis" {
            r set foo bar
            r set fooxxx barxxx
            wait_ssdb_reconnect
            dumpto_ssdb_and_wait r fooxxx

            r $flush
            list [r get foo] [sr get fooxxx] [r get fooxxx]
        } {{} {} {}}
    }
}

# debug populate
start_server {tags {"ssdb"}} {
    set master [srv client]
    set master_host [srv host]
    set master_port [srv port]
    start_server {} {
        set slave [srv client]
        foreach flush $allflush {
            test "single client $flush all keys" {
                $master debug populate 100000
                after 500
                $master $flush
                wait_ssdb_reconnect -1

                wait_for_condition 20 100 {
                    [$master debug digest] == 0000000000000000000000000000000000000000
                } else {
                    fail "Digest not null:master([$master debug digest]) after too long time."
                }
                wait_for_condition 10 100 {
                    [lindex [sr -1 scan 0] 0] eq 0
                } else {
                    fail "ssdb not clear up:[ sr -1 scan 0]"
                }
            }

            test "multi clients $flush all keys" {
                $master debug populate 100000
                after 500
                set clist [start_bg_command_list $master_host $master_port 100 $flush]
                after 1000
                stop_bg_client_list $clist

                wait_ssdb_reconnect -1
                wait_for_condition 20 500 {
                    [$master debug digest] == 0000000000000000000000000000000000000000
                } else {
                    fail "Digest not null:master([$master debug digest]) after too long time."
                }
                wait_for_condition 10 100 {
                    [lindex [sr -1 scan 0] 0] eq 0
                } else {
                    fail "ssdb not clear up:[ sr -1 scan 0]"
                }
            }

            test "replicate and then $flush" {
                $master debug populate 100000
                $slave debug populate 100000
                after 500
                $slave slaveof $master_host $master_port
                set pattern "Sending rr_make_snapshot to SSDB"
                wait_log_pattern $pattern [srv -1 stdout]
                $master $flush
                wait_for_online $master 1
                wait_for_condition 10 500 {
                    [$master debug digest] == 0000000000000000000000000000000000000000 &&
                    [$slave debug digest] == 0000000000000000000000000000000000000000
                } else {
                    fail "Digest not null:master([$master debug digest]) and slave([$slave debug digest]) after too long time."
                }
                list [lindex [sr scan 0] 0] [lindex [sr -1 scan 0] 0]
            } {0 0}

            test "$flush and then replicate" {
                $slave slaveof no one
                after 500
                $master debug populate 100000
                $slave debug populate 100000
                after 500
                $master $flush
                $slave slaveof $master_host $master_port
                wait_for_online $master 1
                wait_for_condition 1 1 {
                    [$master debug digest] == 0000000000000000000000000000000000000000 &&
                    [$slave debug digest] == 0000000000000000000000000000000000000000
                } else {
                    fail "Digest not null:master([$master debug digest]) and slave([$slave debug digest]) after too long time."
                }
                list [lindex [sr scan 0] 0] [lindex [sr -1 scan 0] 0]
            } {0 0}

            test "#issue $flush not propogate to slave after $flush and replicate" {
                $master set foo bar
                wait_for_condition 10 100 {
                    {bar} == [$slave get foo]
                } else {
                    fail "SET on master did not propagated on slave"
                }

                $master $flush
                wait_for_condition 30 100 {
                    [$master debug digest] == 0000000000000000000000000000000000000000 &&
                    [$slave debug digest] == 0000000000000000000000000000000000000000
                } else {
                    fail "Digest not null:master([$master debug digest]) and slave([$slave debug digest]) after too long time."
                }
                list [lindex [sr scan 0] 0] [lindex [sr -1 scan 0] 0]
            } {0 0}

            test "replicate done and then $flush" {
                $slave slaveof no one
                after 500
                $master debug populate 100000
                # $slave debug populate 100000
                after 500
                $slave slaveof $master_host $master_port
                wait_for_online $master 1
# TODO need too long time for slave stable
#                wait_for_condition 15 500 {
#                    [$master debug digest] == [$slave debug digest]
#                } else {
#                    fail "Different digest between master([$master debug digest]) and slave([$slave debug digest]) after too long time."
#                }
                wait_for_condition 100 100 {
                    [$master dbsize] == [$slave dbsize]
                } else {
                    fail "Different number of keys between master and slave after too long time."
                }
                assert {[$master dbsize] == 100000}
                $master $flush
                wait_for_condition 50 500 {
                    [$master debug digest] == 0000000000000000000000000000000000000000 &&
                    [$slave debug digest] == 0000000000000000000000000000000000000000
                } else {
                    fail "Digest not null:master([$master debug digest]) and slave([$slave debug digest]) after $flush."
                }
                wait_for_condition 50 100 {
                    [lindex [sr scan 0] 0] == 0 &&
                    [lindex [sr -1 scan 0] 0] == 0
                } else {
                    fail "ssdb not null after 5s!"
                }
            }
        }
    }
}

# flush during clients writing
start_server {tags {"ssdb"}} {
    set master [srv client]
    set master_host [srv host]
    set master_port [srv port]
    start_server {} {
        set slaves {}
        lappend slaves [srv 0 client]
        start_server {} {
            lappend slaves [srv 0 client]
            set num 10000
            set clients 10
            foreach flush $allflush {
                test "single $flush all keys during clients writing after sync" {
                    set clist [ start_bg_complex_data_list $master_host $master_port $num $clients ]
                    [lindex $slaves 0] slaveof $master_host $master_port
                    wait_for_online $master 1
                    set size_before [$master dbsize]
                    catch { $master $flush } err
                    stop_bg_client_list $clist
                    set size_after [$master dbsize]
                    assert_equal {OK} $err "$flush should return OK"
                    assert {$size_after < $size_before}
                }

                test "master and one slave are identical after $flush" {
                    wait_for_condition 300 100 {
                        [$master dbsize] == [[lindex $slaves 0] dbsize]
                    } else {
                        fail "Different number of keys between master and slaves after too long time."
                    }
                    assert {[$master dbsize] > 0}
                    wait_for_condition 10 500 {
                        [$master debug digest] == [[lindex $slaves 0] debug digest]
                    } else {
                        fail "Different digest between master([$master debug digest]) and slave1([[lindex $slaves 0] debug digest]) after too long time."
                    }
                }

                test "multi $flush all keys during clients writing and sync" {
                    set clist [ start_bg_complex_data_list $master_host $master_port $num $clients ]
                    [lindex $slaves 1] slaveof $master_host $master_port
                    set pattern "Sending rr_make_snapshot to SSDB"
                    wait_log_pattern $pattern [srv -2 stdout]
                    set flushclist [start_bg_command_list $master_host $master_port 100 $flush]
                    after 1000
                    stop_bg_client_list $flushclist
                    after 1000
                    wait_ssdb_reconnect -2
                    stop_bg_client_list $clist
                    $master ping
                } {PONG}

                test "wait two slaves sync" {
                    wait_for_online $master 2
                }

                test "master and two slaves are identical after $flush" {
                    wait_for_condition 100 100 {
                        [$master dbsize] == [[lindex $slaves 0] dbsize] &&
                        [$master dbsize] == [[lindex $slaves 1] dbsize]
                    } else {
                        check_real_diff_keys $master $slaves
                        # fail "Different number of keys between master and slaves after too long time."
                    }
                    assert {[$master dbsize] > 0}
# TODO need too long time for slave stable
#                    wait_for_condition 20 500 {
#                        [$master debug digest] == [[lindex $slaves 0] debug digest] &&
#                        [$master debug digest] == [[lindex $slaves 1] debug digest]
#                    } else {
#                        fail "Different digest between master([$master debug digest]) and slave1([[lindex $slaves 0] debug digest]) slave2([[lindex $slaves 1] debug digest]) after too long time."
#                    }
                }

            }
        }
    }
}

# flush after write
start_server {tags {"ssdb"}} {
    set master [srv client]
    set master_host [srv host]
    set master_port [srv port]
    start_server {} {
        set slaves {}
        lappend slaves [srv 0 client]
        start_server {} {
            lappend slaves [srv 0 client]
            foreach flush $allflush {
                test "multi clients $flush all keys after write and sync" {
                    set num 10000
                    set clients 10
                    set clist [ start_bg_complex_data_list $master_host $master_port $num $clients ]
                    [lindex $slaves 0] slaveof $master_host $master_port
                    wait_for_online $master 1
                    wait_for_condition 100 100 {
                        [sr -1 dbsize] > 0
                    } else {
                        fail "No keys store to slave ssdb"
                    }
                    stop_bg_client_list $clist
                    after 1000
                    set flushclist [start_bg_command_list $master_host $master_port 10 $flush]
                    after 1000
                    stop_bg_client_list $flushclist
                    $master ping
                } {PONG}

                test "master and slave are both null after $flush" {
                    wait_for_condition 300 100 {
                        [$master dbsize] == 0 &&
                        [[lindex $slaves 0] dbsize] == 0
                    } else {
                        fail "Different number of keys between master and slaves after too long time."
                    }
                    wait_for_condition 20 500 {
                        [$master debug digest] == [[lindex $slaves 0] debug digest]
                    } else {
                        fail "Different digest between master([$master debug digest]) and slave([[lindex $slaves 0] debug digest]) after too long time."
                    }
                }

                test "sync with second slave after $flush" {
                    set clist [ start_bg_complex_data_list $master_host $master_port $num $clients ]
                    after 1000
                    [lindex $slaves 1] slaveof $master_host $master_port
                    wait_for_online $master 2
                }

                test "clients write keys after $flush" {
                    wait_for_condition 100 100 {
                        [sr -2 dbsize] > 0 &&
                        [sr -1 dbsize] > 0 &&
                        [sr dbsize] > 0
                    } else {
                        fail "No keys store to ssdb after $flush"
                    }
                    stop_bg_client_list $clist
                }

                test "master and slaves are identical" {
                    wait_for_condition 100 100 {
                        [$master dbsize] == [[lindex $slaves 0] dbsize] &&
                        [$master dbsize] == [[lindex $slaves 1] dbsize]
                    } else {
                        # check_real_diff_keys $master $slaves
                        fail "Different number of keys between master and slaves after too long time."
                    }
                    assert {[$master dbsize] > 0}
                    wait_memory_stable; wait_memory_stable -1; wait_memory_stable -2;
                    if {[$master debug digest] != [[lindex $slaves 0] debug digest] ||
                    [[lindex $slaves 0] debug digest] != [[lindex $slaves 1] debug digest]} {
                        puts "Different digest between master([$master debug digest]) and slave1([[lindex $slaves 0] debug digest]) slave2([[lindex $slaves 1] debug digest])."
                        compare_debug_digest {-2 -1 0}
                    }
                }

                test "master and slaves are clear after $flush again" {
                    $master $flush
                    wait_for_condition 10 500 {
                        [$master debug digest] == 0000000000000000000000000000000000000000 &&
                        [[lindex $slaves 0] debug digest] == 0000000000000000000000000000000000000000 &&
                        [[lindex $slaves 1] debug digest] == 0000000000000000000000000000000000000000
                    } else {
                        fail "Digest not null:master([$master debug digest]) and slave1([[lindex $slaves 0] debug digest]) slave2([[lindex $slaves 1] debug digest]) after too long time."
                    }
                    list [lindex [sr scan 0] 0] [lindex [sr -1 scan 0] 0] [lindex [sr -2 scan 0] 0]
                } {0 0 0}
            }
        }
    }
}

# flush timeout
start_server {tags {"ssdb"}
overrides {client-blocked-by-flushall-timeout 1}} {
    set master [srv client]
    set master_host [srv host]
    set master_port [srv port]
    start_server {} {
        set slaves {}
        lappend slaves [srv 0 client]
        start_server {overrides {slave-blocked-by-flushall-timeout 1}} {
            lappend slaves [srv 0 client]
            foreach flush $allflush {
                test "master flushall timeout with client-blocked-by-flushall-timeout 1" {
                    set num 10000
                    set clients 20
                    set clist [ start_bg_complex_data_list $master_host $master_port $num $clients 10k]
                    [lindex $slaves 0] slaveof $master_host $master_port
                    wait_for_online $master 1
                    stop_bg_client_list $clist
                    after 1000
                    set flushclient [redis $master_host $master_port]
                    catch { $flushclient $flush } ret
                    $master ping
                } {PONG}

                if {![string match "OK" $ret]} {
                    test "master and slave are not clear if $flush return err" {
                        after 3000
                        wait_for_condition 100 100 {
                            [$master dbsize] == [[lindex $slaves 0] dbsize]
                        } else {
                            fail "Different number of keys between master and slaves after too long time."
                        }
                    }
                } else {
                    test "master and slave are both null after $flush" {
                        wait_for_condition 100 100 {
                            [$master dbsize] == 0 &&
                            [[lindex $slaves 0] dbsize] == 0 &&
                            [sr -1 ssdb_dbsize] == 0 &&
                            [sr -2 ssdb_dbsize] == 0
                        } else {
                            fail "master and slaves are not null after too long time."
                        }
                        assert_equal 0 [llength [sr -2 keys *]]
                        assert_equal 0 [llength [sr -1 keys *]]
                        assert_equal 0 [llength [sr -2 ssdb_scan 0 count 1] ] "master ssdb scan should be null"
                        assert_equal 0 [llength [sr -1 ssdb_scan 0 count 1] ] "slave ssdb scan should be null"
                    }
                }

                test "sync with second slave(flush timeout) after $flush" {
                    set clist [ start_bg_complex_data_list $master_host $master_port $num $clients ]
                    after 1000
                    [lindex $slaves 1] slaveof $master_host $master_port
                    wait_for_online $master 2
                }

                test "clients write keys after $flush" {
                    wait_for_condition 100 100 {
                        [sr -2 dbsize] > 0 &&
                        [sr -1 dbsize] > 0 &&
                        [sr dbsize] > 0
                    } else {
                        fail "No keys store to ssdb after $flush"
                    }
                    stop_bg_client_list $clist
                }

                test "master and slaves are identical" {
                    wait_for_condition 100 100 {
                        [$master dbsize] == [[lindex $slaves 0] dbsize] &&
                        [$master dbsize] == [[lindex $slaves 1] dbsize]
                    } else {
                        fail "Different number of keys between master and slaves after too long time."
                    }
                    assert {[$master dbsize] > 0}
                    wait_memory_stable; wait_memory_stable -1; wait_memory_stable -2;
                    if {[$master debug digest] != [[lindex $slaves 0] debug digest] ||
                    [[lindex $slaves 0] debug digest] != [[lindex $slaves 1] debug digest]} {
                        puts "Different digest between master([$master debug digest]) and slave1([[lindex $slaves 0] debug digest]) slave2([[lindex $slaves 1] debug digest])."
                        compare_debug_digest {-2 -1 0}
                    }
                }

                test "slave flushall timeout with slave-blocked-by-flushall-timeout 1" {
                    $master config set client-blocked-by-flushall-timeout 5000
                    $master $flush
                    wait_for_condition 10 500 {
                        [$master debug digest] == 0000000000000000000000000000000000000000 &&
                        [[lindex $slaves 0] debug digest] == 0000000000000000000000000000000000000000 &&
                        [[lindex $slaves 1] debug digest] == 0000000000000000000000000000000000000000
                    } else {
                        fail "Digest not null:master([$master debug digest]) and slave1([[lindex $slaves 0] debug digest]) slave2([[lindex $slaves 1] debug digest]) after too long time."
                    }
                    list [lindex [sr scan 0] 0] [lindex [sr -1 scan 0] 0] [lindex [sr -2 scan 0] 0]
                } {0 0 0}
            }
        }
    }
}
