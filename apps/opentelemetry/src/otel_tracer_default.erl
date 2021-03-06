%%%------------------------------------------------------------------------
%% Copyright 2019, OpenTelemetry Authors
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc
%% @end
%%%-------------------------------------------------------------------------
-module(otel_tracer_default).

-behaviour(otel_tracer).

-export([start_span/3,
         start_span/4,
         with_span/3,
         with_span/4,
         b3_propagators/0,
         w3c_propagators/0]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include("otel_tracer.hrl").
-include("otel_span_ets.hrl").

%% @doc Creates a Span and sets it to the current active Span in the process's Tracer Context.
-spec start_span(opentelemetry:tracer(), opentelemetry:span_name(), otel_span:start_opts())
                -> opentelemetry:span_ctx().
start_span(Tracer={_, #tracer{on_end_processors=OnEndProcessors}}, Name, Opts) ->
    {SpanCtx, _} = start_span(otel_ctx:get_current(), Tracer, Name, Opts),
    SpanCtx#span_ctx{span_sdk={otel_span_ets, OnEndProcessors}}.

%% @doc Starts an inactive Span and returns its SpanCtx.
-spec start_span(otel_ctx:t(), opentelemetry:tracer(), opentelemetry:span_name(),
                 otel_span:start_opts()) -> {opentelemetry:span_ctx(), otel_ctx:t()}.
start_span(Ctx, Tracer={_, #tracer{on_start_processors=Processors,
                                   on_end_processors=OnEndProcessors,
                                   instrumentation_library=InstrumentationLibrary}}, Name, Opts) ->
    ParentSpanCtx = maybe_parent_span_ctx(Ctx),
    Opts1 = maybe_set_sampler(Tracer, Opts),
    SpanCtx = otel_span_ets:start_span(Ctx, Name, ParentSpanCtx, Opts1, Processors, InstrumentationLibrary),
    {SpanCtx#span_ctx{span_sdk={otel_span_ets, OnEndProcessors}}, Ctx}.

maybe_set_sampler(_Tracer, Opts) when is_map_key(sampler, Opts) ->
    Opts;
maybe_set_sampler({_, #tracer{sampler=Sampler}}, Opts) ->
    Opts#{sampler => Sampler}.

%% returns the span `start_opts' map with the parent span ctx set
%% based on the current tracer ctx, the ctx passed to `start_span'
%% or `start_inactive_span' and in the case none of those are defined it
%% checks the `EXTERNAL_SPAN_CTX' which can be set by a propagator extractor.
-spec maybe_parent_span_ctx(otel_ctx:t()) -> opentelemetry:span_ctx() | undefined.
maybe_parent_span_ctx(Ctx) ->
    case otel_tracer:current_span_ctx(Ctx) of
        ActiveSpanCtx=#span_ctx{} ->
            ActiveSpanCtx;
        _ ->
            otel_tracer:current_external_span_ctx()
            %% otel_ctx:get_value(?EXTERNAL_SPAN_CTX)
    end.

-spec with_span(opentelemetry:tracer(), opentelemetry:span_name(), otel_tracer:traced_fun()) -> ok.
with_span(Tracer, SpanName, Fun) ->
    with_span(Tracer, SpanName, #{}, Fun).

-spec with_span(opentelemetry:tracer(), opentelemetry:span_name(),
                otel_span:start_opts(), otel_tracer:traced_fun(T)) -> T.
with_span(Tracer, SpanName, Opts, Fun) ->
    Ctx = otel_ctx:get_current(),
    {SpanCtx, _} = start_span(Ctx, Tracer, SpanName, Opts),
    Ctx1 = otel_tracer:set_current_span(Ctx, SpanCtx),
    otel_ctx:attach(Ctx1),
    try
        Fun(SpanCtx)
    after
        %% passing SpanCtx directly ensures that this `end_span' ends the span started
        %% in this function. If spans in `Fun()' were started and not finished properly
        %% they will be abandoned and it be up to the `otel_span_sweeper' to eventually remove them.
        _ = otel_span_ets:end_span(SpanCtx),
        otel_ctx:attach(Ctx)
    end.

-spec b3_propagators() -> {otel_propagator:text_map_extractor(), otel_propagator:text_map_injector()}.
b3_propagators() ->
    otel_tracer:text_map_propagators(otel_propagator_http_b3).

-spec w3c_propagators() -> {otel_propagator:text_map_extractor(), otel_propagator:text_map_injector()}.
w3c_propagators() ->
    otel_tracer:text_map_propagators(otel_propagator_http_w3c).
