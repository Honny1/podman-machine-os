#!/bin/bash
set -eo pipefail

mkdir -p /etc/systemd/system.conf.d \
         /etc/environment.d \
         /etc/ssh/sshd_config.d \
         /etc/sysctl.d \
         /etc/chrony.d \
         /etc/systemd/system/user@.service.d \
         /usr/share/containers/containers.conf.d \
         /usr/share/containers/registries.conf.d

# Install config files

cat >/etc/chrony.d/50-podman-makestep.conf <<EOF
makestep 1 -1
EOF

echo "confdir /etc/chrony.d" >> /etc/chrony.conf

cat >/etc/profile.d/docker-host.sh <<'EOF'
export DOCKER_HOST="unix://$(podman info -f "{{.Host.RemoteSocket.Path}}")"
EOF

cat >/usr/share/containers/registries.conf.d/999-podman-machine.conf <<EOF
# Issue #11489: make sure that we can inject a custom registries.conf
# file on the system level to force a single search registry.
# The remote client does not yet support prompting for short-name
# resolution, so we enforce a single search registry (i.e., docker.io)
# as a workaround.

unqualified-search-registries=["docker.io"]
EOF

cat >/usr/share/containers/containers.conf.d/999-podman-machine.conf <<EOF
# Starting with Podman 6 we mount the host configs into the VM at /etc/containers, see
# https://github.com/containers/podman/pull/28573
#
# The problem with that is that helper_binaries_dir has two purposes, finding client
# binaries (i.e. gvproxy) but also the server ones (i.e. netavark). If a user sets this
# to a client path they could unset the server default and thus make podman inside the
# VM more or less unusable.
# To fix this lets always append the fedora package path last here.

[engine]
helper_binaries_dir=["/usr/libexec/podman", {append=true}]
EOF

cat >/etc/sysctl.d/10-inotify-instances.conf <<EOF
fs.inotify.max_user_instances=524288
EOF

cat >/etc/ssh/sshd_config.d/99-podman-sshd.conf <<EOF
# There seems to be big problem on macos with connecting to ssh to early and
# it seems to count that as auth failure locking us out. Podman machine only
# runs locally and there ar eno remote users that can connect so just disable
# it.
PerSourcePenalties authfail:0

# If many podman commands are run simultaneously, sshd may drop some of the
# connections. There are no remote users so set the limit very high.
MaxStartups 65535
EOF

## Set delegate.conf so cpu,io subsystem is delegated to non-root users as well for cgroupv2
## by default
cat >/etc/systemd/system/user@.service.d/delegate.conf <<EOF
[Service]
Delegate=memory pids cpu io
EOF


# 1. For main branch builds, replace aardvark-dns, conmon, crun, netavark, podman, containers-common
# 2. For release branch builds, fetch the build from the copr job on the podman
# release PR.
# 3. Remove moby-engine, containerd, runc, zincati for both dev and release builds
# Note: Currently does not result in a size reduction for the container image
# 4. Even though the URLs mention `rawhide`, the repo and gpg files are Fedora
# release agnostic and such `rawhide` URLs are unlikely to change compared to URLs
# containing Fedora release numbers.
if [[ ${PODMAN_PR_NUM} == "" ]]; then \
    curl --fail -o /etc/yum.repos.d/rhcontainerbot-podman-next-fedora.repo https://copr.fedorainfracloud.org/coprs/rhcontainerbot/podman-next/repo/fedora-rawhide/rhcontainerbot-podman-next-fedora-rawhide.repo
    curl --fail -o /etc/pki/rpm-gpg/rhcontainerbot-podman-next-fedora.gpg https://download.copr.fedorainfracloud.org/results/rhcontainerbot/podman-next/pubkey.gpg
    dnf install --best -y \
    aardvark-dns crun netavark podman containers-common containers-common-extra crun-wasm
else
    shopt -s nullglob
    FILE="/var/tmp/rpms/*.rpm"
    if [[ -n $(echo $FILE) ]]; then dnf update -y --best --allowerasing $FILE; fi
    curl --fail -o /etc/yum.repos.d/podman-release-copr.repo https://copr.fedorainfracloud.org/coprs/packit/containers-podman-${PODMAN_PR_NUM}/repo/fedora-rawhide/packit-containers-podman-${PODMAN_PR_NUM}-fedora-rawhide.repo
    curl --fail -o /etc/pki/rpm-gpg/podman-release-copr.gpg https://download.copr.fedorainfracloud.org/results/packit/containers-podman-${PODMAN_PR_NUM}/pubkey.gpg
    dnf install --best -y podman
fi

# Install subscription-manager and enable service to refresh certificates
# Install qemu-user-static for bootc/user emulation
# Install device-mapper (this satisfies the deps for qemu-user-static
# We don't want all weak deps for these packages here.
dnf install -y --setopt=install_weak_deps=false \
    subscription-manager device-mapper qemu-user-static-aarch64 qemu-user-static-x86


# Package list to install
PACKAGES=(
    # for hyperV and WSL user mode networking
    gvisor-tap-vsock-gvforwarder

    # ansible for post-install configuration (podman machine init --playbook)
    ansible-core

    # WSL specific deps (most of them are already in the coreos base so this is a NOP there)
    procps-ng
    openssh-server
    cifs-utils
    nfs-utils-coreos
    iproute
    dhcp-client

    # cpp for buildah.in support
    cpp

    # git-core for Containerfile `ADD <gitrepo>` clone feature
    git-core
    git-daemon

    # Guest agent (vsock) for time sync and host-guest features (macOS vfkit/libkrun)
    qemu-guest-agent

    # --- Developer tools for building podman/buildah from source ---
    # Build essentials
    golang
    gcc
    make
    automake
    autoconf
    libtool
    pkgconfig
    redhat-rpm-config

    # Rust toolchain for netavark/aardvark-dns
    rust
    cargo
    clippy
    rustfmt
    protobuf-compiler
    protobuf-c
    protobuf-devel
    systemd-devel

    # Development libraries required by podman/buildah
    gpgme-devel
    libassuan-devel
    libseccomp-devel
    device-mapper-devel
    btrfs-progs-devel
    glib2-devel
    libselinux-devel
    ostree-devel
    libcap-devel
    libnet-devel
    glibc-devel
    glibc-static
    libblkid-devel

    # container-libs (storage/image/common) development dependencies
    fuse3
    fuse3-devel
    fuse-overlayfs
    composefs
    sqlite-devel
    openssl-devel
    libxml2-devel
    selinux-policy-devel
    container-selinux
    policycoreutils

    # Rootless networking (needed for container-libs/common and podman tests)
    passt
    slirp4netns

    # Netavark/aardvark-dns test utilities (no services)
    bind-utils
    net-tools
    iproute-tc
    nftables

    # Documentation and code generation
    go-md2man
    man-db

    # Testing and linting tools
    bats
    ShellCheck
    python3-pip
    codespell

    # --- Developer experience ---
    vim-enhanced
    tmux
    htop
    jq
    curl
    wget
    rsync
    unzip
    tar
    xz
    zip
    fzf
    ripgrep
    bat
    findutils
    lsof
    socat
    nmap-ncat

    # Container/image tools
    skopeo
    buildah

    # Conformance test dependencies (install docker on-demand, not at image build)
    runc
    bzip2
)

dnf install -y "${PACKAGES[@]}"

# Install golangci-lint (used by container-libs, podman, buildah for linting)
curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh | sh -s -- -b /usr/local/bin

# Remove unwanted packages
dnf remove -y toolbox qed-firmware moby-engine containerd runc docker-cli 2>/dev/null || true

# Clean caches
rm -fr /var/cache
dnf -y clean all

systemctl enable rhsmcertd.service
# Patching qemu backed binfmt configurations to use the actual executable's permissions and not the interpreter's
for x in /usr/lib/binfmt.d/*.conf; do sed 's/\(:[^C:]*\)$/\1PC/' "$x" | tee /etc/binfmt.d/"$(basename "$x")"; done
