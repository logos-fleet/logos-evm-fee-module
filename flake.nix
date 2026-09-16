{
  description = "Logos fee_module — EIP-1559 fee suggestion (slow/normal/fast) for EVM chains, derived from eth_feeHistory.";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # Without the follows it drags its own module-builder, and a skewed generated ABI
    # segfaults the module inside provider init.
    eth_rpc_module = {
      url = "github:logos-co/logos-evm-eth-rpc-module";
      inputs.logos-module-builder.follows = "logos-module-builder";
    };
  };

  outputs = inputs@{ self, logos-module-builder, ... }:
    let
      nixpkgs = logos-module-builder.inputs.nixpkgs;
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];

      # x86_64-windows is a cross PSEUDO-SYSTEM the builder already understands
      # (logos-module-builder lib/common.nix routes it to
      # logos-nix.lib.mkWindowsPkgs, and picks the build platform separately).
      # It is a target, never a host we evaluate nixpkgs natively for, so it
      # only ever belongs in `packages`.
      targets = systems ++ [ "x86_64-windows" ];

      # ONE module, answered for every target at once — mkLogosModule already
      # keys its own outputs by system, so calling it inside a genAttrs
      # evaluated the same module once per target and threw all but one away.
      module = logos-module-builder.lib.mkLogosModule {
        src = ./.;
        configFile = ./metadata.json;
        flakeInputs = inputs;
      };

      # The mobile pseudo-systems logos-nix keys its cross package sets by. Kept
      # out of `targets` above for the reason the builder keeps them out of its
      # own: a phone gets the Bare image and none of the other outputs.
      #
      # THIS IS WHAT MAKES fee_module BUNDLABLE (#183). A phone's Bundled set is
      # resolved out of a catalog whose every entry is a module's own
      # `mobile.<target>.bare`, so a module with no mobile output cannot be in
      # that set however well it builds on a desktop. That absence was one of
      # the two reasons `wallet_backend_module` — which calls
      # `modules().fee_module.estimate(...)` on both the quote path and the send
      # path — could not join a Bundled set at all: a member's whole
      # `dependencies` closure has to be in the catalog or the set is refused by
      # name at eval, and a phone that cannot price a send has no Send tab.
      #
      # NOTHING HAD TO CHANGE IN THE MODULE to cross, and that is the point of
      # this being a flake edit rather than a port. The crate is `serde` +
      # `serde_json` + a `default-features = false` `sha3`: fee arithmetic in
      # u128, deliberately no `alloy`, no C dependency, no
      # `nix.external_libraries`. The one call that leaves the process goes out
      # through `modules().eth_rpc_module`, which is a native Bare module beside
      # it in the same Bundled set.
      #
      # `? ${t}` rather than a bare index, so a logos-module-builder pin without
      # the mobile cross sets leaves this flake simply WITHOUT mobile keys
      # instead of failing to evaluate.
      mobileTargets = builtins.filter (t: module.packages ? ${t})
        [ "aarch64-ios" "aarch64-ios-simulator" "aarch64-android" ];
    in
    {
      packages = nixpkgs.lib.genAttrs (targets ++ mobileTargets)
        (target: module.packages.${target});

      # An Android cross derivation's `system` is its BUILD platform, so
      # `packages.aarch64-android` is pinned to the builder's canonical one
      # (x86_64-linux) and a Mac cannot realise it. The same artifact, reached
      # from whichever machine is doing the building:
      #   nix build .#legacyPackages.aarch64-darwin.mobile.aarch64-android.bare
      legacyPackages = module.legacyPackages or { };

      # THE MODULE'S OWN ANSWER ABOUT ITSELF, forwarded so a consumer flake can
      # read it without building anything. logos-basecamp's mobile catalog takes
      # this module's `version` and its `dependencies` from here rather than
      # restating them: a Bundled set resolves a CLOSURE out of the catalog
      # entry, so `--bundle fee_module` has to bring `eth_rpc_module` along
      # without naming it, and a hand-copied list in a SIGNED manifest is a
      # claim the core would act on after it had drifted.
      # `configFor` is the per-target resolution of the same document; this
      # module has no `platforms` overlay, so the two agree everywhere.
      inherit (module) config configFor;

      # ── WHY THERE IS NO `web` (wasm) OUTPUT HERE ─────────────────────────
      #
      # Nothing withholds one: this module is not `platform: true` and the
      # builder publishes `packages.<system>.web` whenever its pin's
      # logos-protocol carries the wasm outbound door (ADR 0009). It simply is
      # not what a phone uses. fee_module reaches a device as a NATIVE Bundled
      # Bare module in the app image (the mobile keys above), and the callers
      # that matter — `wallet_backend_module` on the Bundled side, the wallet
      # UI's `web` variant through the container — reach it BY NAME over the
      # ordinary provider registry.
    };
}
