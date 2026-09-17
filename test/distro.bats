#!/usr/bin/env bats
# lib/distro.sh: resolving the packages of the *running* kernel.
#
# The machine running the suite must not change the answers, so pacman and the module tree are
# both fixtures (t1r_stub_pacman). The case that matters is Omarchy's: the booted kernel comes
# from linux-omarchy while a stock, unbooted `linux` is installed as well - reading `linux`
# named a kernel that is not running and asked for headers dkms never builds against
# (issues #7 and #9).

load test_helper/common

setup() {
  t1r_env
  [[ -f $T1R_REPO/lib/distro.sh ]] || skip "lib/distro.sh not present"
  t1r_use_osrelease arch
  t1r_stub_pacman
  t1r_load distro
  t1r_need distro_kernel_pkg distro_headers_pkg distro_required_pkgs distro_kernel_matches
}

# the Omarchy layout: a booted linux-omarchy and an installed but unbooted stock linux
omarchy_layout() {
  t1r_pacman_installed linux 7.2.3.arch1-3
  t1r_pacman_installed linux-headers 7.2.3.arch1-3
  t1r_pacman_installed linux-omarchy 7.2.5-3
  t1r_pacman_installed linux-omarchy-headers 7.2.5-3
  t1r_pacman_owns "$(t1r_kernel_dir)/vmlinuz" linux-omarchy
  t1r_pacman_owns "$(t1r_kernel_dir)/build" linux-omarchy-headers
}

@test "distro_kernel_pkg: names the package that owns the running kernel, not linux" {
  omarchy_layout
  run distro_kernel_pkg
  assert_status 0
  assert_eq linux-omarchy "$output"
}

@test "distro_kernel_pkg: the stock layout still answers linux" {
  t1r_pacman_installed linux 7.2.3.arch1-3
  t1r_pacman_owns "$(t1r_kernel_dir)/vmlinuz" linux
  run distro_kernel_pkg
  assert_status 0
  assert_eq linux "$output"
}

@test "distro_kernel_pkg: a kernel no package owns returns 1 and prints nothing" {
  t1r_pacman_installed linux 7.2.3.arch1-3
  run distro_kernel_pkg
  assert_status 1
  assert_eq '' "$output"
}

@test "distro_headers_pkg: the owner of the running kernel's build directory" {
  omarchy_layout
  run distro_headers_pkg
  assert_status 0
  assert_eq linux-omarchy-headers "$output"
}

@test "distro_headers_pkg: headers not installed yet -> <kernel package>-headers" {
  t1r_pacman_installed linux-omarchy 7.2.5-3
  t1r_pacman_owns "$(t1r_kernel_dir)/vmlinuz" linux-omarchy
  run distro_headers_pkg
  assert_status 0
  assert_eq linux-omarchy-headers "$output"
}

@test "distro_headers_pkg: falls back to the stock linux-headers when nothing resolves" {
  run distro_headers_pkg
  assert_status 0
  assert_eq linux-headers "$output"
}

@test "distro_required_pkgs: the fixed list plus the headers of the running kernel" {
  omarchy_layout
  run distro_required_pkgs
  assert_status 0
  assert_contains "$output" 'acpi_call-dkms'
  assert_contains "$output" 'linux-omarchy-headers'
  refute_contains " $output " ' linux-headers '
}

@test "distro_installed: the resolved headers package is installed, the stock one need not be" {
  t1r_pacman_installed linux-omarchy 7.2.5-3
  t1r_pacman_installed linux-omarchy-headers 7.2.5-3
  t1r_pacman_owns "$(t1r_kernel_dir)/vmlinuz" linux-omarchy
  t1r_pacman_owns "$(t1r_kernel_dir)/build" linux-omarchy-headers
  run distro_installed "$(distro_headers_pkg)"
  assert_status 0
  run distro_installed linux-headers
  assert_status 1
}

@test "distro_kernel_matches: ownership of the running kernel is enough" {
  t1r_pacman_installed linux 7.2.3.arch1-3
  t1r_pacman_installed linux-omarchy 7.2.5-3
  t1r_pacman_owns "$(t1r_kernel_dir)/vmlinuz" linux-omarchy
  run distro_kernel_matches
  assert_status 0
}

@test "distro_kernel_matches: no owner and a linux version that differs -> 1" {
  t1r_pacman_installed linux 1.2.3.arch1-1
  run distro_kernel_matches
  assert_status 1
}

@test "distro_headers_present: reads the running kernel's build directory" {
  run distro_headers_present
  assert_status 1
  mkdir -p "$(t1r_kernel_dir)/build"
  run distro_headers_present
  assert_status 0
}

@test "sourcing lib/distro.sh has no side effects" {
  run bash -c "source '$T1R_REPO/lib/distro.sh'"
  assert_status 0
  assert_eq '' "$output"
}
