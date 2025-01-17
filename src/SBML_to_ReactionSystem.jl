"""
    SBML_to_ReactionSystem(path_SBML::AbstractString;
                           ifelse_to_callback::Bool=true,
                           inline_assignment_rules::Bool=false,
                           write_to_file::Bool=false, 
                           verbose::Bool=true, 
                           return_all::Bool=false, 
                           model_as_string::Bool=false)

Parse an SBML model into a Catalyst `ReactionSystem` and potentially convert events/piecewise to callbacks.

For information on simulating the `ReactionSystem`, refer to the documentation.

For converting the SBML model directly into a ModelingToolkit `ODESystem` see the function `SBML_to_ODESystem`.

For testing `path_SBML` can be the model as a string if `model_as_string=true`.

!!! note
    The number of returned arguments depends on whether the SBML model has events and/or piecewise expressions (see below).

## Arguments
- `path_SBML`: File path to a valid SBML file (level 2 or higher).
- `ifelse_to_callback=true`: Whether to rewrite `ifelse` (piecewise) expressions to callbacks; recommended for performance.
- `inline_assignment_rules=true`: Whether to inline assignment rules into model equations. Recomended for model import speed, 
    however, note that it will not be possible to access the rule-variable then via sol[:var]
- `write_to_file=false`: Whether to write the parsed SBML model to a Julia file in the same directory as the SBML file.
- `verbose=true`: Whether or not to display information on the number of return arguments.
- `return_all=true`: Whether or not to return all possible arguments (see below), regardless of whether the model has events.
- `model_as_string=false` : Whether or not the model (`path_SBML`) is provided as a string, for testing.

## Returns
- `rn`: A Catalyst `ReactionSystem` that for example can be converted into an `ODEProblem` and solved.
- `specie_map`: A species map setting initial values; together with the `ReactionSystem`, it can be converted into an `ODEProblem`.
- `parameter_map` A parameter map setting parameter values; together with the `ReactionSystem`, it can be converted into an `ODEProblem`.
- `cbset` - **only for models with events/piecewise expressions**: Callbackset (events) for the model.
- `get_tstops`- **Only for models with events/piecewise expressions**: Function computing time stops for discrete callbacks in the `cbset`.

## Examples
```julia
# Import and simulate model without events
using SBMLImporter
rn, specie_map, parameter_map = SBML_to_ReactionSystem(path_SBML)
sys = convert(ODESystem, rn)

using OrdinaryDiffEq
tspan = (0, 10.0)
prob = ODEProblem(sys, specie_map, tspan, parameter_map, jac=true)
# Solve ODE with Rodas5P solver
sol = solve(prob, Rodas5P())
```
```julia
# Import a model with events
using SBMLImporter
rn, specie_map, parameter_map, cb, get_tstops = SBML_to_ReactionSystem(path_SBML)
sys = convert(ODESystem, rn)

using OrdinaryDiffEq
tspan = (0, 10.0)
prob = ODEProblem(sys, specie_map, tspan, parameter_map, jac=true)
# Compute event times
tstops = get_tstops(prob.u0, prob.p)
sol = solve(prob, Rodas5P(), tstops=tstops, callback=callbacks)
```
"""                 
function SBML_to_ReactionSystem(path_SBML::T;
                                ifelse_to_callback::Bool=true,
                                inline_assignment_rules::Bool=true,
                                write_to_file::Bool=false, 
                                verbose::Bool=true, 
                                ret_all::Bool=false, 
                                model_as_string::Bool=false) where T <: AbstractString

    # Intermediate model representation of a SBML model which can be processed into
    # an ODESystem
    model_SBML = build_SBML_model(path_SBML; ifelse_to_callback=ifelse_to_callback, 
                                  model_as_string=model_as_string, inline_assignment_rules=inline_assignment_rules)                                    

    # If model is written to file save it in the same directory as the SBML-file
    dir_save = model_as_string ? joinpath(@__DIR__, "SBML") : joinpath(splitdir(path_SBML)[1], "SBML")
    if write_to_file == true && !isdir(dir_save)
        mkdir(dir_save)
    end
    path_save_model = joinpath(dir_save, model_SBML.name * ".jl")

    # Build the ReactionSystem. Must be done via Meta-parse, because if a function is used 
    # via @RuntimeGeneratedFunction runtime is very slow for large models
    parsed_model_SBML = _reactionsystem_from_SBML(model_SBML)
    # The model can have have only species or only variables or both. If it has variables they 
    # are given via SBML rules
    eval(Meta.parse("ModelingToolkit.@variables t"))
    eval(Meta.parse("D = Differential(t)"))
    sps = parsed_model_SBML.no_species ? Any[] : eval(Meta.parse(split(parsed_model_SBML.species, "\n")[2]))
    vs = isempty(model_SBML.rule_variables) ? Any[] : eval(Meta.parse(parsed_model_SBML.variables))
    if isempty(model_SBML.rule_variables)
        sps_arg = sps
    elseif parsed_model_SBML.no_species == false
        sps_arg = [sps; vs]
    else
        sps_arg = vs
    end                                  
    # Parameters can not be an empty collection
    if parsed_model_SBML.parameters != "\tps = Catalyst.@parameters "
        ps = eval(Meta.parse(parsed_model_SBML.parameters))
    else
        ps = Any[]
    end
    _reactions = eval(Meta.parse(parsed_model_SBML.reactions))
    combinatoric_ratelaws = parsed_model_SBML.int_stoichiometries ? true : false
    # Build reaction system from its components
    reaction_system = Catalyst.ReactionSystem(_reactions, t, sps_arg, ps; name=Symbol(model_SBML.name), combinatoric_ratelaws=combinatoric_ratelaws)
    specie_map = eval(Meta.parse(parsed_model_SBML.specie_map))
    parameter_map = eval(Meta.parse(parsed_model_SBML.parameter_map))

    # Build callback functions 
    cbset, callback_str = create_callbacks_SBML(reaction_system, model_SBML, model_SBML.name)

    # if model is written to file write the callback
    if write_to_file == true
        path_save = joinpath(dir_save, model_SBML.name * "_callbacks.jl")
        io = open(path_save, "w")
        write(io, callback_str)
        close(io)
        _ = reactionsystem_to_string(parsed_model_SBML, write_to_file, path_save_model, 
                                     model_SBML)
    end

    if ret_all == true
        return reaction_system, specie_map, parameter_map, cbset
    end

    # Depending on model return what is needed to perform forward simulations
    if isempty(model_SBML.events) && isempty(model_SBML.ifelse_bool_expressions)
        return reaction_system, specie_map, parameter_map
    end
    
    verbose && @info "SBML model with events - output returned as odesys, specie_map, parameter_map, cbset\nFor how to simulate model see documentation"
    return reaction_system, specie_map, parameter_map, cbset
end


# Parse the model into a string, which then via Meta.parse becomes a ReactionSystem
function _reactionsystem_from_SBML(model_SBML::ModelSBML)::ModelSBMLString

    # Check if model is empty of derivatives if the case add dummy state to be able to
    # simulate the model
    if ((isempty(model_SBML.species) || sum([!s.assignment_rule for s in values(model_SBML.species)]) == 0) &&
        (isempty(model_SBML.parameters) || sum([p.rate_rule for p in values(model_SBML.parameters)]) == 0) &&
        (isempty(model_SBML.compartments) || sum([c.rate_rule for c in values(model_SBML.compartments)]) == 0))

        model_SBML.species["foo"] = SpecieSBML("foo", false, false, "1.0", "0.0", "1.0", "", :Amount,
                                                  false, false, false, false)
    end

    # Setup Catalyst ReactionNetwork
    _species_write, _specie_map_write = SBMLImporter.get_specie_map(model_SBML, reaction_system=true)
    _parameters_write, _parameter_map_write = SBMLImporter.get_parameter_map(model_SBML, reaction_system=true)

    # In case a specie (or parameter) appear as a rate-rule, algebraic or assignment rule they need to be treated as
    # MTK variable for the the downstream processing. This might turn the species block empty, then it must be removed
    _variables_write = "\tvs = ModelingToolkit.@variables"
    for variable in model_SBML.rule_variables
        _species_write = replace(_species_write, " " * variable * "(t)" => "")
        _variables_write *= " " * variable * "(t)"
    end
    if !isempty(model_SBML.rule_variables)
        no_species = all([x ∈ model_SBML.rule_variables for x in keys(model_SBML.species)])
    else
        no_species = false
    end

    # Reaction stoichiometry and propensities
    int_stoichiometries::Bool = true
    _reactions = "\t_reactions = [\n"
    for (id, r) in model_SBML.reactions

        # Can happen for models with species that are boundary conditions, such species 
        # do not take part in reactions 
        if all(r.products .== "nothing") && all(r.reactants .== "nothing")
            continue
        end

        reactants_stoichiometries, reactants, int_stoichiometries1 = get_reaction_side(r, :Reactants, model_SBML)
        products_stoichiometries, products, int_stoichiometries2 = get_reaction_side(r, :Products, model_SBML)
        propensity = r.kinetic_math
        if reaction_is_mass_action(r, model_SBML) == true && int_stoichiometries1 && int_stoichiometries2
            _reactions *= ("\t\tSBMLImporter.update_rate_reaction(Catalyst.Reaction(" * propensity * ", " *
                            reactants * ", " * products * ", " *
                            reactants_stoichiometries * ", " * products_stoichiometries * "; only_use_rate=false)),\n")
        else
            _reactions *= ("\t\tCatalyst.Reaction(" * propensity * ", " *
                           reactants * ", " * products * ", " *
                           reactants_stoichiometries * ", " * products_stoichiometries * "; only_use_rate=true),\n")
        end
                        
        # If it has already been assigned false we know that all stoichiometries are not
        # integer numbers, and if either of int_stoichiometries are false int_stoichiometries
        # should become false
        if int_stoichiometries == true
            int_stoichiometries = !any([int_stoichiometries1, int_stoichiometries2] .== false)
        end
    end

    # Rules are directly encoded into the Catalyst.Reaction vector
    for variable in unique(Iterators.flatten((model_SBML.rate_rule_variables, model_SBML.assignment_rule_variables)))
        if haskey(model_SBML.species, variable)
            @unpack formula, assignment_rule, rate_rule = model_SBML.species[variable]
        elseif haskey(model_SBML.parameters, variable)
            @unpack formula, assignment_rule, rate_rule = model_SBML.parameters[variable]
        elseif haskey(model_SBML.compartments, variable)
            @unpack formula, assignment_rule, rate_rule = model_SBML.compartments[variable]
        else
            continue
        end
        if rate_rule == true
            _reactions *= "\t\tD(" * variable * ") ~ " * formula * ",\n"
        elseif assignment_rule == true
            _reactions *= "\t\t" * variable * " ~ " * formula * ",\n"
        end
    end
    # Algebriac rules are already encoded as 0 ~ formula
    for formula in values(model_SBML.algebraic_rules)
        _reactions *= "\t\t" * formula * ",\n"
    end
    _reactions *= "\t]\n"

    return ModelSBMLString(_species_write, _specie_map_write, _variables_write, 
                           _parameters_write, _parameter_map_write, _reactions, 
                           no_species, int_stoichiometries)
end


function reactionsystem_to_string(parsed_model_SBML::ModelSBMLString,
                                  write_to_file::Bool, path_save_model::String, 
                                  model_SBML::ModelSBML)::String

    # ReactionSystem
    combinatoric_ratelaws_arg = parsed_model_SBML.int_stoichiometries ? "true" : "false"
    _species_write = parsed_model_SBML.species
    if isempty(model_SBML.rule_variables)
        sps_arg = "sps"
    elseif parsed_model_SBML.no_species == false
        sps_arg = "[sps; vs]"
    else
        sps_arg = "vs"
        _species_write = replace(_species_write, "sps = Catalyst.@species" => "")
    end                                  
    # Parameters might be an empty set
    if parsed_model_SBML.parameters != "\tps = Catalyst.@parameters "
        _rn_write = "\trn = Catalyst.ReactionSystem(reactions, t, $sps_arg, ps; name=Symbol(\"" * model_SBML.name * "\"), combinatoric_ratelaws=$combinatoric_ratelaws_arg)"
    else
        _rn_write = "\trn = Catalyst.ReactionSystem(reactions, t, $sps_arg, Any[]; name=Symbol(\"" * model_SBML.name * "\"), combinatoric_ratelaws=$combinatoric_ratelaws_arg)"
    end

    # Create a function returning the ReactionSystem, specie-map, and parameter-map
    _function_write = "function get_reaction_system(foo)\n\n"
    _function_write *= _species_write * "\n"
    if parsed_model_SBML.variables != "\tvs = ModelingToolkit.@variables"
        _function_write *= parsed_model_SBML.variables * "\n"
    end
    if parsed_model_SBML.parameters != "\tps = Catalyst.@parameters "
        _function_write *= parsed_model_SBML.parameters * "\n\n"
    end
    _function_write *= "\tD = Differential(t)\n\n"
    _function_write *= parsed_model_SBML.reactions * "\n\n"
    _function_write *= _rn_write * "\n\n"
    _function_write *= parsed_model_SBML.specie_map * "\n"
    _function_write *= parsed_model_SBML.parameter_map * "\n"
    _function_write *= "\treturn rn, specie_map, parameter_map\nend"

    # In case user request file to be written
    if write_to_file == true
        open(path_save_model, "w") do f
            write(f, _function_write)
        end
    end

    return _function_write
end



function get_reaction_side(r::ReactionSBML, which_side::Symbol, 
                           model_SBML::ModelSBML)::Tuple{String, String, Bool}

    if which_side === :Reactants
        species, stoichiometries = r.reactants, r.reactants_stoichiometry
    elseif which_side === :Products
        species, stoichiometries = r.products, r.products_stoichiometry
    end

    # Case where we go from ϕ -> prod (or reverse)
    if isempty(species)
        return "nothing", "nothing", true
    end
    # Edge case for boundary condition and rate rule
    if length(species) == 1 && species[1] == "nothing"
        return "nothing", "nothing", true
    end

    # Process the _toichiometry for the reaction, species vector is not 
    # required to be unique hence potential double counting must be 
    # considered (role of k-index)
    k = 1
    _stoichiometries = Vector{String}(undef, length(filter(x -> x != "nothing", unique(species))))
    _species_parsed = fill("", length(filter(x -> x != "nothing", unique(species))))
    integer_stoichiometry::Bool = true
    # Happens when all reactants or products are boundary condition
    if isempty(_species_parsed)
        return "nothing", "nothing", true
    end
    for i in eachindex(species)

        # Happens when a specie is a boundary condition, it should not be involved in the reaction and 
        # should affect reaction dynamics
        if species[i] == "nothing"
            continue
        end

        stoichiometry, _integer_stoichiometry = parse_stoichiometry_reaction_system(stoichiometries[i])

        # SBML models can have conversion factors that scale stoichiometry, in this case the stoichiometry
        # is not an integer stoichiometry
        if isempty(model_SBML.species[species[i]].conversion_factor) && isempty(model_SBML.conversion_factor)
            _stoichiometry = stoichiometry 
            if integer_stoichiometry == true
                integer_stoichiometry = _integer_stoichiometry
            end
        else
            cv_specie = model_SBML.species[species[i]].conversion_factor
            cv = isempty(cv_specie) ? model_SBML.conversion_factor : cv_specie
            _stoichiometry = stoichiometry * "*" * cv 
            integer_stoichiometry = false
        end

        # Species are allowed to be repeated in SBML reactions, this is not 
        # allowed in Catalyst, therefore stoichiometry for these repititions 
        # are added up 
        if species[i] ∈ _species_parsed
            _i = findfirst(x -> x == species[i], _species_parsed)
            _stoichiometries[_i] *= "+" * _stoichiometry
        else
            _species_parsed[k] = species[i]
            _stoichiometries[k] = _stoichiometry
            k += 1
        end

    end
    _stoichiometries_str = "[" * prod([s * ", " for s in _stoichiometries])[1:end-2] * "]"
    _species_str = "[" * prod([s * ", " for s in _species_parsed])[1:end-2] * "]"

    return _stoichiometries_str, _species_str, integer_stoichiometry
end


# If possible parse stoichiometry to an integer
function parse_stoichiometry_reaction_system(stoichiometry::String)::Tuple{String, Bool}
    if !isnothing(tryparse(Float64, stoichiometry))
        _stoichiometry = parse(Float64, stoichiometry)
        try
            return string(Int64(_stoichiometry)), true
        catch
            return string(_stoichiometry), false
        end
    else
        return stoichiometry, false
    end
end


"""
    function reaction_is_mass_action(r::ReactionSBML, model_SBML::ModelSBML)::Bool

Check if a Catalyst recation should be converted to a mass-action reaction, occurs if:

* Involved species has only_substance_unit=true
* Propensity does not include time t, or depend on rate-rule or assignment rule variables
* Stoichiometry is mass-action. In case reactants or products have a specie-id then the reaction 
  does not have to be mass-action following SBML standard
"""
function reaction_is_mass_action(r::ReactionSBML, model_SBML::ModelSBML)::Bool

    if r.stoichiometry_mass_action == false
        return false
    end

    for specie in Iterators.flatten((r.reactants, r.products))
        if specie == "nothing"
            continue
        end
        if model_SBML.species[specie].only_substance_units == false
            return false
        end
    end

    # Check that no rule variables appear in formula
    formula = r.kinetic_math
    for rule_variable in model_SBML.rule_variables
        if SBMLImporter.replace_variable(formula, rule_variable, "") != formula
            return false
        end
    end

    return true
end


function update_rate_reaction(rx; combinatoric_ratelaw::Bool=true)
    @set rx.rate = (rx.rate^2) / Catalyst.oderatelaw(rx; combinatoric_ratelaw=combinatoric_ratelaw)
end


# Helper for exporting SBML models 
function get_specie_map(model_SBML::ModelSBML; reaction_system::Bool=false)::Tuple{String, String}

    if reaction_system == false
        _species_write = "\tModelingToolkit.@variables t "
    else
        _species_write = "\tModelingToolkit.@variables t\n\tsps = Catalyst.@species "
    end
    _specie_map_write = "\tspecie_map = [\n"
    
    # Identify which variables/parameters are dynamic 
    for specie_id in keys(model_SBML.species)
        _species_write *= specie_id * "(t) "
    end
    for (parameter_id, parameter) in model_SBML.parameters
        if parameter.constant == true
            continue
        end
        # Happens when the assignment rule has been inlined, and thus should not be included 
        # as a model variable with an initial value
        if (parameter.assignment_rule == true && 
            parameter_id ∉ model_SBML.algebraic_rule_variables && 
            parameter.rate_rule == false)
            continue
        end
        _species_write *= parameter_id * "(t) "
    end
    for (compartment_id, compartment) in model_SBML.compartments
        if compartment.constant == true
            continue
        end
        _species_write *= compartment_id * "(t) "
    end

    # Map for initial values on time-dependent parameters 
    for (specie_id, specie) in model_SBML.species
        u0eq = specie.initial_value
        _specie_map_write *= "\t" * specie_id * " =>" * u0eq * ",\n"
    end
    # Parameters
    for (parameter_id, parameter) in model_SBML.parameters
        if !(parameter.rate_rule == true || parameter.assignment_rule == true)
            continue
        end
        # See comment above
        if (parameter.assignment_rule == true && 
            parameter_id ∉ model_SBML.algebraic_rule_variables && 
            parameter.rate_rule == false)
            continue
        end
        u0eq = parameter.initial_value
        _specie_map_write *= "\t" * parameter_id * " => " * u0eq * ",\n"
    end
    # Compartments
    for (compartment_id, compartment) in model_SBML.compartments
        if compartment.rate_rule != true
            continue
        end
        u0eq = compartment.initial_value
        _specie_map_write *= "\t" * compartment_id * " => " * u0eq * ",\n"
    end
    _specie_map_write *= "\t]"


    return _species_write, _specie_map_write
end


# For when exporting to ODESystem or ReactionSystem 
function get_parameter_map(model_SBML::ModelSBML; reaction_system::Bool=false)::Tuple{String, String}

    if reaction_system == false
        _parameters_write = "\tModelingToolkit.@parameters "
    else
        _parameters_write = "\tps = Catalyst.@parameters "
    end
    _parameter_map_write = "\tparameter_map = [\n"
    
    for (parameter_id, parameter) in model_SBML.parameters
        if parameter.constant == false
            continue
        end
        # For ReactionSystem we carefully need to separate species and variables
        if reaction_system == true && parameter.assignment_rule == true
            continue
        end
        # In case assignment rule variables have been inlined they should not be 
        # a part of the parameter-map 
        if parameter.assignment_rule == true && parameter_id ∉ model_SBML.assignment_rule_variables
            continue
        end
        _parameters_write *= parameter_id * " "
    end
    for (compartment_id, compartment) in model_SBML.compartments
        if compartment.constant == false
            continue
        end
        # For ReactionSystem we carefully need to separate species and variables
        if reaction_system == true && compartment.assignment_rule == true
            continue
        end
        _parameters_write *= compartment_id * " "
    end
    # Special case where we do not have any parameters
    if length(_parameters_write) == 29 && _parameters_write[1:14] != "\tps = Catalyst"
        _parameters_write = ""
    end

    # Map setting initial values for parameters 
    for (parameter_id, parameter) in model_SBML.parameters
        if parameter.constant == false
            continue
        end
        # In case assignment rule variables have been inlined they should not be 
        # a part of the parameter-map 
        if parameter.assignment_rule == true && parameter_id ∉ model_SBML.assignment_rule_variables
            continue
        end
        peq = parameter.formula
        _parameter_map_write *= "\t" * parameter_id * " =>" * peq * ",\n"
    end
    for (compartment_id, compartment) in model_SBML.compartments
        if compartment.constant == false
            continue
        end
        ceq = compartment.formula
        _parameter_map_write *= "\t" * compartment_id * " =>" * ceq * ",\n"
    end
    _parameter_map_write *= "\t]"

    return _parameters_write, _parameter_map_write
end