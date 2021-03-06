# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""TypeScript rules.
"""
# pylint: disable=unused-argument
# pylint: disable=missing-docstring
load(":common/compilation.bzl", "COMMON_ATTRIBUTES", "compile_ts", "ts_providers_dict_to_struct")
load(":executables.bzl", "get_tsc")
load(":common/tsconfig.bzl", "create_tsconfig")
load(":ts_config.bzl", "TsConfigInfo")
load("//:internal/common/collect_es6_sources.bzl", "collect_es6_sources")
load("@io_bazel_rules_closure//closure:defs.bzl", "closure_js_binary")    

def _compile_action(ctx, inputs, outputs, tsconfig_file):
  externs_files = []
  action_outputs = []
  for output in outputs:
    if output.basename.endswith(".es5.MF"):
      ctx.file_action(output, content="")
    else:
      action_outputs.append(output)

  if not action_outputs:
    return struct()

  action_inputs = inputs + [f for f in ctx.files.node_modules + ctx.files._tsc_wrapped_deps
                            if f.path.endswith(".js") or f.path.endswith(".ts") or f.path.endswith(".json")]
  if ctx.file.tsconfig:
    action_inputs += [ctx.file.tsconfig]
    if TsConfigInfo in ctx.attr.tsconfig:
      action_inputs += ctx.attr.tsconfig[TsConfigInfo].deps

  # One at-sign makes this a params-file, enabling the worker strategy.
  # Two at-signs escapes the argument so it's passed through to tsc_wrapped
  # rather than the contents getting expanded.
  if ctx.attr.supports_workers:
    arguments = ["@@" + tsconfig_file.path]
    mnemonic = "TypeScriptCompile"
  else:
    arguments = ["-p", tsconfig_file.path]
    mnemonic = "tsc"

  ctx.action(
      progress_message = "Compiling TypeScript (devmode) %s" % ctx.label,
      mnemonic = mnemonic,
      inputs = action_inputs,
      outputs = action_outputs,
      arguments = arguments,
      executable = ctx.executable.compiler,
      execution_requirements = {
          "supports-workers": str(int(ctx.attr.supports_workers)),
      },
  )

  # Enable the replay_params in case an aspect needs to re-build this library.
  return struct(
      label = ctx.label,
      tsconfig = tsconfig_file,
      inputs = action_inputs,
      outputs = action_outputs,
      compiler = ctx.executable.compiler,
  )


def _devmode_compile_action(ctx, inputs, outputs, tsconfig_file):
  _compile_action(ctx, inputs, outputs, tsconfig_file)

def tsc_wrapped_tsconfig(ctx,
                         files,
                         srcs,
                         devmode_manifest=None,
                         jsx_factory=None,
                         **kwargs):
  """Produce a tsconfig.json that sets options required under Bazel.
  """

  # The location of tsconfig.json is interpreted as the root of the project
  # when it is passed to the TS compiler with the `-p` option:
  #   https://www.typescriptlang.org/docs/handbook/tsconfig-json.html.
  # Our tsconfig.json is in bazel-foo/bazel-out/local-fastbuild/bin/{package_path}
  # because it's generated in the execution phase. However, our source files are in
  # bazel-foo/ and therefore we need to strip some parent directories for each
  # f.path.

  config = create_tsconfig(ctx, files, srcs,
                           devmode_manifest=devmode_manifest,
                           **kwargs)
  config["bazelOptions"]["nodeModulesPrefix"] = "/".join([p for p in [
    ctx.attr.node_modules.label.workspace_root,
    ctx.attr.node_modules.label.package,
    "node_modules"
  ] if p])

  if config["compilerOptions"]["target"] == "es6":
    config["compilerOptions"]["module"] = "es2015"
  else:
    # The "typescript.es5_sources" provider is expected to work
    # in both nodejs and in browsers.
    # NOTE: tsc-wrapped will always name the enclosed AMD modules
    config["compilerOptions"]["module"] = "umd"

  # If the user gives a tsconfig attribute, the generated file should extend
  # from the user's tsconfig.
  # See https://github.com/Microsoft/TypeScript/issues/9876
  # We subtract the ".json" from the end before handing to TypeScript because
  # this gives extra error-checking.
  if ctx.file.tsconfig:
    workspace_path = config["compilerOptions"]["rootDir"]
    config["extends"] = "/".join([workspace_path, ctx.file.tsconfig.path[:-len(".json")]])

  if jsx_factory:
    config["compilerOptions"]["jsxFactory"] = jsx_factory

  return config

# ************ #
# ts_library   #
# ************ #


def _ts_library_impl(ctx):
  """Implementation of ts_library.

  Args:
    ctx: the context.

  Returns:
    the struct returned by the call to compile_ts.
  """
  ts_providers = compile_ts(ctx, is_library=True,
                            compile_action=_compile_action,
                            devmode_compile_action=_devmode_compile_action,
                            tsc_wrapped_tsconfig=tsc_wrapped_tsconfig)
  return ts_providers_dict_to_struct(ts_providers)

ts_library = rule(
    _ts_library_impl,
    attrs = dict(COMMON_ATTRIBUTES, **{
        "srcs":
            attr.label_list(
                allow_files=FileType([
                    ".ts",
                    ".tsx",
                ]),
                mandatory=True,),

        # TODO(alexeagle): reconcile with google3: ts_library rules should
        # be portable across internal/external, so we need this attribute
        # internally as well.
        "tsconfig":
            attr.label(allow_files = True, single_file = True),
        "compiler":
            attr.label(
                default=get_tsc(),
                single_file=False,
                allow_files=True,
                executable=True,
                cfg="host"),
        "supports_workers": attr.bool(default = True),
        "tsickle_typed": attr.bool(default = True),
        "_tsc_wrapped_deps": attr.label(default = Label("@build_bazel_rules_typescript_tsc_wrapped_deps//:node_modules")),
        # @// is special syntax for the "main" repository
        # The default assumes the user specified a target "node_modules" in their
        # root BUILD file.
        "node_modules": attr.label(default = Label("@//:node_modules")),
    }),
    outputs = {
        "tsconfig": "%{name}_tsconfig.json"
    }
)

# Helper that compiles typescript libraries using the vanilla tsc compiler
# Only used in Bazel - this file is not intended for use with Blaze.
def tsc_library(**kwargs):
  ts_library(
      supports_workers = False,
      compiler = "//internal/tsc_wrapped:tsc",
      node_modules = "@build_bazel_rules_typescript_tsc_wrapped_deps//:node_modules",
      **kwargs)

# ******************* #
# closure_ts_binary   #
# ******************* #
def _collect_es6_sources_impl(ctx):
  """Rule which wraps the collect_es6_sources action for rules_closure.

  Args:
    ctx: the context.

  Returns:
    A closure_js_library with the rerooted files.
  """
  collected_es6_sources = collect_es6_sources(ctx)

  js_module_roots = depset()
  for prod_file in collected_es6_sources:
    if "node_modules/" in prod_file.dirname:
      js_module_roots += [prod_file.dirname[:prod_file.dirname.find('node_modules/')]]

  return struct(
    files = collected_es6_sources,
    closure_js_library = struct(
      srcs = collected_es6_sources,
      js_module_roots = js_module_roots,
    )
  )

_collect_es6_sources = rule(
    attrs = {"deps": attr.label_list(mandatory = True)},
    implementation = _collect_es6_sources_impl,
)

def closure_ts_binary(name, deps, **kwargs):
  _collect_es6_sources_label = name + "_collect_es6_sources"
  _collect_es6_sources(name = _collect_es6_sources_label, deps = deps)

  closure_js_binary(
    name = name,
    deps = [":" + _collect_es6_sources_label],
    **kwargs
  )  
