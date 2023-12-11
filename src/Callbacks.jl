# Function generating callbacksets for time-depedent SBML piecewise expressions, as callbacks are more efficient than
# using ifelse (for example better integration stability, faster runtimes etc...)
function create_callbacks_SBML(system,
                               model_SBML::ModelSBML,
                               model_name::String)::Tuple{String, String}

    p_ode_problem_names::Vector{String} = string.(parameters(system))
    model_specie_names::Vector{String} = replace.(string.(states(system)), "(t)" => "")

    # Set function names 
    model_name = replace(model_name, "-" => "_")
    write_callbacks = "function get_callbacks_" * model_name * "(foo)\n"
    write_tstops = "\nfunction compute_tstops(u::AbstractVector, p::AbstractVector)\n"

    # In case we do not have any SBML related events
    if isempty(model_SBML.ifelse_parameters) && isempty(model_SBML.events)
        callback_names = ""
        check_activated_t0_names = ""
        write_tstops *= "\t return Float64[]\nend\n"
    else

        # For ifelse parameter
        for parameter in keys(model_SBML.ifelse_parameters)
            function_str, callback_formula =  create_callback_ifelse(parameter, model_SBML, p_ode_problem_names, model_specie_names)
            write_callbacks *= function_str * "\n" * callback_formula * "\n"
        end
        # For classical SBML events 
        for key in keys(model_SBML.events)
            function_str, callback_formula = create_callback_SBML_event(key, model_SBML, p_ode_problem_names, model_specie_names)
            write_callbacks *= function_str * "\n" * callback_formula * "\n"
        end

        callback_names = get_callback_names(model_SBML)

        # Only relevant for picewise expressions
        if !isempty(model_SBML.ifelse_parameters)
            check_activated_t0_names = prod(["is_active_t0_" * key * "!, " for key in keys(model_SBML.ifelse_parameters)])[1:end-2]
        else
            check_activated_t0_names = ""
        end

        _write_tstops = create_tstops_function(model_SBML, model_specie_names, p_ode_problem_names)
        write_tstops *= "\treturn" * _write_tstops  * "\n" * "end"
    end

    # Write callback to file if required, otherwise just return the string for the callback and tstops functions
    write_callbacks *= "\treturn CallbackSet(" * callback_names * "), Function[" * check_activated_t0_names * "]" * "\nend"
    return write_callbacks, write_tstops
end


function get_callback_names(model_SBML::ModelSBML)::String
    _callback_names = vcat([key for key in keys(model_SBML.ifelse_parameters)], [key for key in keys(model_SBML.events)])
    callback_names = prod(["cb_" * name * ", " for name in _callback_names])[1:end-2]
    return callback_names
end


function create_callback_ifelse(parameter_name::String,
                                model_SBML::ModelSBML,
                                p_ode_problem_names::Vector{String},
                                model_specie_names::Vector{String})::Tuple{String, String}

    # Check if the event trigger depend on parameters which are to be i) estimated, or ii) if it depend on models state.
    # For i) we need to convert tspan. For ii) we cannot compute tstops (the event times) prior to starting to solve 
    # the ODE so it most be cont. callback
    _condition, side_activated_with_time = model_SBML.ifelse_parameters[parameter_name]
    discrete_event = !(check_condition_has_states(_condition, model_specie_names))

    # Replace any state or parameter with their corresponding index in the ODE system to be comaptible with event
    # syntax
    for (i, specie_name) in pairs(model_specie_names)
        _condition = replace_variable(_condition, specie_name, "u["*string(i)*"]")
    end
    for (i, p_name) in pairs(p_ode_problem_names)
        _condition = replace_variable(_condition, p_name, "integrator.p["*string(i)*"]")
    end

    # Replace inequality with - (root finding cont. event) or with == in case of
    # discrete event
    replace_with = discrete_event == true ? "==" : "-"
    _condition_for_t0 = deepcopy(_condition) # Needed for checking active at t0 function
    _condition = replace(_condition, r"<=|>=|>|<" => replace_with)

    # Build the condition function
    condition_function = "\n\tfunction condition_" * parameter_name * "(u, t, integrator)\n"
    condition_function *= "\t\t" * _condition * "\n\tend\n"

    # Build the affect function
    i_ifelse_parameter = findfirst(x -> x == parameter_name, p_ode_problem_names)
    affect_function = "\tfunction affect_" * parameter_name * "!(integrator)\n"
    affect_function *= "\t\tintegrator.p[" * string(i_ifelse_parameter) * "] = 1.0\n\tend\n"

    # Build the callback formula
    if discrete_event == false
        callback_formula = "\tcb_" * parameter_name * " = ContinuousCallback(" * "condition_" * parameter_name * ", " * "affect_" * parameter_name * "!, "
    else
        callback_formula = "\tcb_" * parameter_name * " = DiscreteCallback(" * "condition_" * parameter_name * ", " * "affect_" * parameter_name * "!, "
    end
    callback_formula *= "save_positions=(false, false))\n" # So we do not get problems with saveat in the ODE solver

    # Building a function which check if a callback is activated at time zero (as this is not something Julia will
    # check for us so must be done here)
    side_inequality = side_activated_with_time == "right" ? "!" : "" # Check if true or false evaluates expression to true
    active_t0_function = "\tfunction is_active_t0_" * parameter_name * "!(u, p)\n"
    active_t0_function *= "\t\tt = 0.0 # Used to check conditions activated at t0=0\n" * "\t\tp[" * string(i_ifelse_parameter) * "] = 0.0 # Default to being off\n"
    condition_active_t0 = replace(_condition_for_t0, "integrator." => "")
    active_t0_function *= "\t\tif " * side_inequality *"(" * condition_active_t0 * ")\n" * "\t\t\tp[" * string(i_ifelse_parameter) * "] = 1.0\n\t\tend\n\tend\n"

    # Gather all the functions needed by the callback
    callback_functions = condition_function * '\n' * affect_function * '\n' * active_t0_function * '\n'

    return callback_functions, callback_formula
end


function create_callback_SBML_event(event_name::String,
                                    model_SBML::ModelSBML,
                                    p_ode_problem_names::Vector{String},
                                    model_specie_names::Vector{String})::Tuple{String, String}

    event = model_SBML.events[event_name]
    _condition = event.trigger
    affects = event.formulas
    initial_value_cond = event.trigger_initial_value

    discrete_event = !(check_condition_has_states(_condition, model_specie_names))

    # If the event trigger does not contain a model state but fixed parameters it can at a maximum be triggered once.
    if discrete_event == false
        # If we have a trigger on the form a ≤ b then event should only be
        # activated when crossing the condition from left -> right. Reverse
        # holds for ≥
        affect_neg = occursin("≤", _condition)
    else
        # Build the SBML activation, which has a check to see that the condition crosses from false to 
        # true, per SBML standard 
        _condition = "\tcond = " * _condition * " && from_neg[1] == true\n\t\tfrom_neg[1] = !(" * _condition * ")\n\t\treturn cond"
    end

    # Replace any state or parameter with their corresponding index in the ODE system to be comaptible with event
    # syntax
    for (i, specie_name) in pairs(model_specie_names)
        _condition = replace_variable(_condition, specie_name, "u["*string(i)*"]")
    end
    for (i, p_name) in pairs(p_ode_problem_names)
        _condition = replace_variable(_condition, p_name, "integrator.p["*string(i)*"]")
    end
    # Build the condition function used in Julia file, for discrete checking that event indeed is coming from negative 
    # direction
    if discrete_event == false
        _condition_at_t0 = deepcopy(_condition)
        _condition = replace(_condition, r"≤|≥" => "-")
        condition_function = "\n\tfunction condition_" * event_name * "(u, t, integrator)\n\t\t" * _condition * "\n\tend\n"
    else
        condition_function = "\n\tfunction _condition_" * event_name * "(u, t, integrator, from_neg)\n"
        condition_function *= "\t" * _condition * "\n\tend\n"
        condition_function *= "\n\tcondition_" * event_name * " = let from_neg=" * "[" * string(!initial_value_cond) * "]\n\t\t(u, t, integrator) -> _condition_" * event_name * "(u, t, integrator, from_neg)\n\tend\n"
    end

    # Building the affect function (which can act on multiple states and/or parameters)
    affect_function = "\tfunction affect_" * event_name * "!(integrator)\n\t\tu_tmp = similar(integrator.u)\n\t\tu_tmp .= integrator.u\n"
    for (i, affect) in pairs(affects)
        # In RHS we use u_tmp to not let order affects, while in assigning LHS we use u
        affect_function1, affect_function2 = split(affect, "=")
        for j in eachindex(model_specie_names)
            affect_function1 = replace_variable(affect_function1, model_specie_names[j], "integrator.u["*string(j)*"]")
            affect_function2 = replace_variable(affect_function2, model_specie_names[j], "u_tmp["*string(j)*"]")
        end
        affect_function *= "\t\t" * affect_function1 * " = " * affect_function2 * '\n'
    end
    affect_function *= "\tend"
    for i in eachindex(p_ode_problem_names)
        affect_function = replace_variable(affect_function, p_ode_problem_names[i], "integrator.p["*string(i)*"]")
    end

    # In case the event can be activated at time zero build an initialisation function
    if discrete_event == true && initial_value_cond == false
        initial_value_str = "\tfunction init_" * event_name * "(c,u,t,integrator)\n"
        initial_value_str *= "\t\tcond = condition_" * event_name * "(u, t, integrator)\n"
        initial_value_str *= "\t\tif cond == true\n"
        initial_value_str *= "\t\t\taffect_" * event_name * "!(integrator)\n\t\tend\n"
        initial_value_str *= "\tend"
    elseif discrete_event == false && initial_value_cond == false
        initial_value_str = "\tfunction init_" * event_name * "(c,u,t,integrator)\n"
        initial_value_str *= "\t\tcond = " * _condition_at_t0 * "\n" # We need a Bool not minus (-) condition
        initial_value_str *= "\t\tif cond == true\n"
        initial_value_str *= "\t\t\taffect_" * event_name * "!(integrator)\n\t\tend\n"
        initial_value_str *= "\tend"
    else
        initial_value_str = ""
    end

    # Build the callback, consider initialisation if needed and direction for ContinuousCallback
    if discrete_event == false
        if affect_neg == true
            callback_formula = "\tcb_" * event_name * " = ContinuousCallback(" * "condition_" * event_name * ", nothing, " * "affect_" * event_name * "!,"
        else
            callback_formula = "\tcb_" * event_name * " = ContinuousCallback(" * "condition_" * event_name * ", " * "affect_" * event_name * "!, nothing,"
        end
        if initial_value_cond == false
            callback_formula *= " initialize=init_" * event_name * ", "
        end
    elseif discrete_event == true
        if initial_value_cond == false
            callback_formula = "\tcb_" * event_name * " = DiscreteCallback(" * "condition_" * event_name * ", " * "affect_" * event_name * "!, initialize=init_" * event_name * ", "
        else
            callback_formula = "\tcb_" * event_name * " = DiscreteCallback(" * "condition_" * event_name * ", " * "affect_" * event_name * "!, "
        end
    end
    callback_formula *= "save_positions=(false, false))\n" # So we do not get problems with saveat in the ODE solver

    function_str = condition_function * '\n' * affect_function * '\n' * initial_value_str * '\n'

    return function_str, callback_formula
end


# Function computing t-stops (time for events) for piecewise expressions using the symbolics package
# to symboically solve for where the condition is zero.
function create_tstops_function(model_SBML::ModelSBML,
                                model_specie_names::Vector{String},
                                p_ode_problem_names::Vector{String})::String

    conditions = string.(vcat([model_SBML.ifelse_parameters[key][1] for key in keys(model_SBML.ifelse_parameters)], [e.trigger for e in values(model_SBML.events)]))

    tstops = Vector{String}(undef, length(conditions))
    tstops_to_float = Vector{String}(undef, length(conditions))
    for (i, condition) in pairs(conditions)

        # In case the activation formula contains a state we cannot precompute the t-stop time as it depends on
        # the actual ODE solution.
        if check_condition_has_states(condition, model_specie_names)
            tstops[i] = ""
            tstops_to_float[i] = ""
            continue
        end

        # We need to make the parameters and states symbolic in order to solve the condition expression
        # using the Symbolics package.
        _variables = "@variables t, "
        _variables *= prod(string.(collect(p_ode_problem_names)) .* ", " )[1:end-2] * " "
        _variables *= prod(string.(collect(model_specie_names)) .* ", " )[1:end-2]
        variables_symbolic = eval(Meta.parse(_variables))

        # Note - below order counts (e.g having < first results in ~= incase what actually stands is <=)
        _condition = replace(condition, r"≤|≥|<=|>=|<|>|==" => "~")
        condition_symbolic = eval(Meta.parse(_condition))

        # Expression for the time at which the condition is triggered
        local expression_time
        try
            expression_time = string.(Symbolics.solve_for(condition_symbolic, variables_symbolic[1], simplify=true))
        catch
            throw(SBMLSupport("Not possible to solve for time event is activated"))
        end

        for (i, specie_name) in pairs(model_specie_names)
            expression_time = replace_variable(expression_time, specie_name, "u["*string(i)*"]")
        end
        for (i, p_name) in pairs(p_ode_problem_names)
            expression_time = replace_variable(expression_time, p_name, "p["*string(i)*"]")
        end

        # dual_to_float is needed as tstops for the integrator cannot be of type Dual
        tstops[i] = expression_time # Used when we convert timespan
        i += 1
    end

    _tstops = " Float64[" * prod([isempty(_t) ? "" : _t * ", " for _t  in tstops])[1:end-2] * "]"

    return _tstops
end


function check_condition_has_states(condition::AbstractString, model_specie_names::Vector{String})::Bool
    for i in eachindex(model_specie_names)
        _condition = replace_variable(condition, model_specie_names[i], "")
        if _condition != condition
            return true
        end
    end
    return false
end
