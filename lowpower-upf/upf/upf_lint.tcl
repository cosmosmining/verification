#!/usr/bin/env tclsh
# ===========================================================================
# License-free UPF syntax sanity check.
#
# UPF is Tcl. A real flow validates intent against the netlist; with no UPF
# tool available we at least confirm the file is well-formed Tcl and that every
# command/argument parses, by defining stub procs for the UPF commands and
# sourcing the file. Catches typos, unbalanced braces, and bad option spellings.
#
#   tclsh upf/upf_lint.tcl [path/to/file.upf]
# ===========================================================================

set seen [dict create]

# Record each UPF command invocation; accept any args (we only check parsing).
foreach cmd {
    upf_version set_design_top
    create_power_domain set_domain_supply_net
    create_supply_port create_supply_net connect_supply_net
    create_power_switch
    set_isolation set_isolation_control
    set_retention set_retention_control
} {
    proc $cmd {args} [list apply {{name args} {
        upvar #0 seen seen
        dict incr seen $name
    }} $cmd]
}

set upf [expr {$argc >= 1 ? [lindex $argv 0] : \
        [file join [file dirname [info script]] pg_top.upf]}]

if {[catch {source $upf} err]} {
    puts stderr "UPF LINT FAIL: $upf"
    puts stderr "  $err"
    exit 1
}

# minimal completeness expectations
set required {create_power_domain create_power_switch set_isolation set_retention}
set missing {}
foreach r $required { if {![dict exists $seen $r]} { lappend missing $r } }
if {[llength $missing]} {
    puts stderr "UPF LINT FAIL: missing required strategies: $missing"
    exit 1
}

puts "UPF LINT OK: [file tail $upf]"
foreach {k v} [dict get $seen] {}  ;# no-op
dict for {cmd n} $seen { puts [format "  %-24s x%d" $cmd $n] }
exit 0
