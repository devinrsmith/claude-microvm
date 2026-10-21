# The guest's root services read the launcher's .microvm-env as data, never as
# code. The file sits in /home/agent, which the agent can write, and the agent
# may `sudo systemctl restart` any unit — so a root service that sources it
# runs whatever the agent appended, as root.
#
#   - scripts/microvm-env-get.sh, the reader they use: last match wins, values
#     come back literally, nothing in the file is evaluated;
#   - cri-proxy-env and cri-activate, run here from their evaluated `script`
#     text against a scratch env file, with their fixed paths redirected and
#     systemctl stubbed: a hostile file runs nothing, and a well-formed one does
#     what it did before;
#   - no unit in the evaluated guest that names .microvm-env sources it.
{ pkgs, lib, config }:

let
  envGet = pkgs.writeShellApplication {
    name = "microvm-env-get";
    text = builtins.readFile ../scripts/microvm-env-get.sh;
  };

  services = config.systemd.services;

  # A service's script with its fixed paths moved under $T, so it can run
  # unprivileged against a scratch env file.
  relocate = name: pkgs.writeText "${name}.sh" (lib.replaceStrings
    [ "/home/agent/.microvm-env" "/run/cri-proxy.env" "/etc/crictl.yaml" ]
    [ "$T/env" "$T/run/cri-proxy.env" "$T/etc/crictl.yaml" ]
    services.${name}.script);

  readers = lib.filterAttrs (_: s: lib.hasInfix ".microvm-env" (s.script or "")) services;
  sources = s: lib.any (p: lib.hasInfix p s.script)
    [ ''source "$ENV_FILE"'' ''. "$ENV_FILE"'' "source /home/agent/.microvm-env" ". /home/agent/.microvm-env" ];

  structural = [
    {
      name = "cri-proxy-env and cri-activate read .microvm-env";
      ok = readers ? cri-proxy-env && readers ? cri-activate;
    }
    {
      name = "no unit that reads .microvm-env sources it (${lib.concatStringsSep ", " (lib.attrNames readers)})";
      ok = !lib.any sources (lib.attrValues readers);
    }
  ];
in
pkgs.runCommand "env-file-data-only" { } ''
  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  ${lib.concatMapStrings (c: if c.ok then ''ok ${lib.escapeShellArg c.name}
  '' else ''bad ${lib.escapeShellArg c.name}
  '') structural}

  get=${envGet}/bin/microvm-env-get
  canary="$TMPDIR/canary"
  pwned () { [ -e "$canary" ]; }

  # Every form a sourced line could use to run something. Each one writes the
  # canary if it is ever evaluated.
  hostile () {
    cat <<EOF
  touch $canary
  ENABLE_CRI=\$(touch $canary)docker
  EGRESS_POLICY=\`touch $canary\`shadow
  EGRESS_PROXY_ADDR=10.0.2.100:3128; touch $canary
  FOO=bar touch $canary
  EOF
  }

  # --- the reader -------------------------------------------------------------
  E=$TMPDIR/reader.env
  printf '%s\n' 'ENABLE_CRI=docker' 'ENABLE_CRI_EXTRA=nope' 'EGRESS_PROXY_ADDR=10.0.2.100:3128' \
    'AGENTS_ARGS=-p\ \"hi\ there\"' 'URLISH=a=b=c' 'ENABLE_CRI=podman' > $E
  printf 'LAST=no-newline' >> $E
  [ "$($get $E ENABLE_CRI)" = podman ] && ok "the last line for a key wins, as EXTRA_ENV relies on" || bad "last match: got '$($get $E ENABLE_CRI)'"
  [ "$($get $E ENABLE_CRI_EXTRA)" = nope ] && ok "a key is not matched by a longer one" || bad "key prefix confused"
  [ "$($get $E URLISH)" = a=b=c ] && ok "a value keeps its own '='" || bad "value split on '='"
  [ "$($get $E AGENTS_ARGS)" = '-p\ \"hi\ there\"' ] && ok "a quoted value comes back literally, unevaluated" || bad "quoted value: got '$($get $E AGENTS_ARGS)'"
  [ "$($get $E LAST)" = no-newline ] && ok "a final line without a newline is read" || bad "final line dropped"
  [ -z "$($get $E MISSING)" ] && ok "a missing key reads as empty" || bad "missing key not empty"
  [ -z "$($get $TMPDIR/absent MISSING)" ] && ok "a missing file reads as empty" || bad "missing file not empty"
  if $get $E 'X;touch $canary' 2>/dev/null; then bad "a malformed key was accepted"; else ok "a malformed key is refused"; fi

  hostile > $TMPDIR/hostile.env
  for k in ENABLE_CRI EGRESS_POLICY EGRESS_PROXY_ADDR FOO; do $get $TMPDIR/hostile.env $k >/dev/null; done
  pwned && bad "the reader evaluated the env file" || ok "the reader evaluates nothing in a hostile file"
  [ "$($get $TMPDIR/hostile.env ENABLE_CRI)" = "\$(touch $canary)docker" ] \
    && ok "a command substitution comes back as text" || bad "command substitution: got '$($get $TMPDIR/hostile.env ENABLE_CRI)'"

  # --- the services -----------------------------------------------------------
  mkdir -p $TMPDIR/bin
  cat > $TMPDIR/bin/systemctl <<'EOF'
  #!/bin/sh
  echo "$*" >> "$T/systemctl.log"
  EOF
  for c in chgrp chmod; do printf '#!/bin/sh\n' > $TMPDIR/bin/$c; done
  chmod +x $TMPDIR/bin/*

  svc () { # name case env-file-content
    export T=$TMPDIR/$1-$2; mkdir -p $T/run $T/etc
    printf '%s\n' "$3" > $T/env
    PATH=$TMPDIR/bin:$PATH ${pkgs.bash}/bin/bash -e "$4" > $T/out 2>&1
  }

  svc proxy sealed $'EGRESS_POLICY=shadow\nEGRESS_PROXY_ADDR=10.0.2.100:3128' ${relocate "cri-proxy-env"}
  grep -qx 'HTTPS_PROXY=http://10.0.2.100:3128' $T/run/cri-proxy.env 2>/dev/null \
    && ok "cri-proxy-env: sealed, the daemons get the proxy" || { bad "cri-proxy-env: no proxy env when sealed"; cat $T/out >&2; }

  svc proxy open $'EGRESS_POLICY=open\nEGRESS_PROXY_ADDR=10.0.2.100:3128' ${relocate "cri-proxy-env"}
  [ ! -e $T/run/cri-proxy.env ] && ok "cri-proxy-env: unsealed, writes nothing" || bad "cri-proxy-env: wrote proxy env unsealed"

  svc proxy override $'EGRESS_POLICY=shadow\nEGRESS_PROXY_ADDR=10.0.2.100:3128\nEGRESS_POLICY=open' ${relocate "cri-proxy-env"}
  [ ! -e $T/run/cri-proxy.env ] && ok "cri-proxy-env: a later EGRESS_POLICY line overrides" || bad "cri-proxy-env: ignored a later EGRESS_POLICY"

  rm -f "$canary"
  svc proxy hostile "$(hostile)" ${relocate "cri-proxy-env"}
  pwned && bad "cri-proxy-env ran code from the env file" || ok "cri-proxy-env runs nothing from a hostile env file"

  svc proxy badaddr $'EGRESS_POLICY=enforce\nEGRESS_PROXY_ADDR=10.0.2.100:3128 FOO=1' ${relocate "cri-proxy-env"}
  if [ ! -e $T/run/cri-proxy.env ] && grep -q 'not host:port' $T/out; then
    ok "cri-proxy-env: an EGRESS_PROXY_ADDR that is not host:port is refused"
  else bad "cri-proxy-env: wrote a malformed EGRESS_PROXY_ADDR"; cat $T/run/cri-proxy.env $T/out >&2 2>/dev/null || true; fi

  svc activate typical $'ENABLE_CRI=containerd\nENABLE_CRI=docker,podman' ${relocate "cri-activate"}
  if [ "$(cat $T/systemctl.log 2>/dev/null)" = $'start docker\nstart podman.socket' ]; then
    ok "cri-activate: starts the runtimes in the last ENABLE_CRI line"
  else bad "cri-activate: wrong runtimes started"; cat $T/systemctl.log $T/out >&2 2>/dev/null || true; fi

  svc activate unset 'EGRESS_POLICY=open' ${relocate "cri-activate"}
  [ ! -e $T/systemctl.log ] && ok "cri-activate: without ENABLE_CRI, starts nothing" || bad "cri-activate: started something unasked"

  rm -f "$canary"
  svc activate hostile "$(hostile)" ${relocate "cri-activate"}
  pwned && bad "cri-activate ran code from the env file" || ok "cri-activate runs nothing from a hostile env file"
  [ ! -e $T/systemctl.log ] && ok "cri-activate: a hostile ENABLE_CRI starts nothing" || bad "cri-activate: hostile ENABLE_CRI started: $(cat $T/systemctl.log)"

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
