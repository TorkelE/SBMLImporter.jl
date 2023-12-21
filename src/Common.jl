"""
    replace_variable(formula::T, to_replace::String, replace_with::String)::T where T<:AbstractString

In a formula replaces to_replace with replace_with. Exact match is required, so if to_replace=time1
and replace_with=1 while formula = time * 2 nothing is replaced.
"""
function replace_variable(formula::T, to_replace::String, replace_with::String)::T where T<:AbstractString

    _to_replace = Regex("(\\b" * to_replace * "\\b)")
    return replace(formula, _to_replace => replace_with)
end


"""
    process_SBML_str_formula(formula::T, model_SBML::ModelSBML, libsbml_model::SBML.Model; 
                             check_scaling::Bool=false, rate_rule::Bool=false)::T where T<:AbstractString

Processes a string formula by inserting SBML functions, rewriting piecewise to ifelse, and scaling species
"""
function process_SBML_str_formula(formula::T, model_SBML::ModelSBML, libsbml_model::SBML.Model; 
                                  check_scaling::Bool=false, rate_rule::Bool=false)::T where T<:AbstractString
    
    _formula = SBML_function_to_math(formula, model_SBML.functions)
    if occursin("piecewise(", _formula)
        _formula = piecewise_to_ifelse(_formula, model_SBML, libsbml_model)
    end
    _formula = replace_variable(_formula, "time", "t") # Sometimes t is decoded as time

    # SBML equations are given in concentration, in case an amount specie appears in the equation scale with the 
    # compartment in the formula every time the species appear
    for (specie_id, specie) in model_SBML.species
        if check_scaling == false
            continue
        end
        if specie.unit == :Concentration || specie.only_substance_units == true
            continue
        end

        compartment = specie.compartment
        _formula = replace_variable(_formula, specie_id, "(" * specie_id * "/" * compartment * ")")
    end

    # Replace potential expressions given in initial assignment and that appear in stoichemetric experssions
    # of reactions (these are not species, only math expressions that should be replaced)
    for id in keys(libsbml_model.initial_assignments)
        # In case ID does not occur in stoichemetric expressions
        if isempty(libsbml_model.reactions)
            continue
        end
        if id ∉ reduce(vcat, vcat([[_r.id for _r in r.products] for r in values(libsbml_model.reactions)], [[_r.id for _r in r.reactants] for r in values(libsbml_model.reactions)]))
            continue
        end
        if id ∉ keys(model_SBML.species) && rate_rule == false
            continue
        end
        if isnothing(id)
            continue
        end
        # Do not rewrite is stoichemetric is controlled via event
        if !isempty(model_SBML.events) && any(occursin.(id, reduce(vcat, [e.formulas for e in values(model_SBML.events)])))
            continue
        end
        if rate_rule == false
            _formula = replace_variable(_formula, id, "(" * model_SBML.species[id].initial_value * ")")
        else
            replace_with = parse_SBML_math(libsbml_model.initial_assignments[id])
            _formula = replace_variable(_formula, id, "(" * replace_with * ")")
        end
    end

    # Sometimes we have a stoichemetric expression appearing in for example rule expressions, etc... but it does not 
    # have any initial assignment, or rule assignment. In this case the reference should be replaced with its corresponding 
    # stoichemetry
    for (_, reaction) in libsbml_model.reactions
        specie_references = vcat([reactant for reactant in reaction.reactants], [product for product in reaction.products])
        for specie_reference in specie_references
            if isnothing(specie_reference.id)
                continue
            end
            if specie_reference.id ∈ keys(libsbml_model.initial_assignments)
                continue
            end
            if specie_reference.id ∈ [rule isa SBML.AlgebraicRule ? "" : rule.variable for rule in libsbml_model.rules]
                continue
            end
            if specie_reference.id ∈ keys(libsbml_model.species)
                continue
            end
            _formula = replace_variable(_formula, specie_reference.id, string(specie_reference.stoichiometry))
        end
    end

    return _formula
end


function time_in_formula(formula::String)::Bool
    _formula = replace_variable(formula, "t", "")
    return formula != _formula
end


function replace_reactionid_formula(formula::T, libsbml_model::SBML.Model)::T where T<:AbstractString
    for (reaction_id, reaction) in libsbml_model.reactions
        reaction_math = parse_SBML_math(reaction.kinetic_math)
        formula = replace_variable(formula, reaction_id, reaction_math)
    end
    return formula
end


function replace_rateOf!(model_SBML::ModelSBML)::Nothing

    for (parameter_id, parameter) in model_SBML.parameters
        parameter.formula = replace_rateOf(parameter.formula, model_SBML)
        parameter.initial_value = replace_rateOf(parameter.initial_value, model_SBML)
    end
    for (specie_id, specie) in model_SBML.species
        specie.formula = replace_rateOf(specie.formula, model_SBML)
        specie.initial_value = replace_rateOf(specie.initial_value, model_SBML)
    end
    for (event_id, event) in model_SBML.events
        for (i, formula) in pairs(event.formulas)
            event.formulas[i] = replace_rateOf(formula, model_SBML)
        end
        event.trigger = replace_rateOf(event.trigger, model_SBML)
    end
    for (rule_id, rule) in model_SBML.algebraic_rules
        model_SBML.algebraic_rules[rule_id] = replace_rateOf(rule, model_SBML)
    end

    return nothing
end


function replace_rateOf(_formula::T, model_SBML::ModelSBML)::String where T<:Union{<:AbstractString, <:Real}

    formula = string(_formula)
    if !occursin("rateOf", formula)
        return formula
    end

    # Invalid character problems
    formula = replace(formula, "≤" => "<=")
    formula = replace(formula, "≥" => ">=")

    # Find rateof expressions
    start_rateof = findall(i -> formula[i:(i+6)] == "rateOf(", 1:(length(formula)-6))
    end_rateof = [findfirst(x -> x == ')', formula[start:end])+start-1 for start in start_rateof]
    # Compenstate for nested paranthesis 
    for i in eachindex(end_rateof) 
        if any(occursin.(['*', '/'], formula[start_rateof[i]:end_rateof[i]]))
            end_rateof[i] += 1
        end
    end
    args = [formula[start_rateof[i]+7:end_rateof[i]-1] for i in eachindex(start_rateof)]

    replace_with = Vector{String}(undef, length(args))
    for (i, arg) in pairs(args)

        # A constant parameter does not have a rate
        if arg ∈ keys(model_SBML.parameters) && model_SBML.parameters[arg].constant == true
            replace_with[i] = "0.0"
            continue
        end
        # A parameter via a rate-rule has a rate
        if arg ∈ keys(model_SBML.parameters) && model_SBML.parameters[arg].rate_rule == true
            replace_with[i] = model_SBML.parameters[arg].formula
            continue
        end

        # A number does not have a rate
        if is_number(arg)
            replace_with[i] = "0.0"
            continue
        end

        # If specie is via a rate-rule we do not scale the state in the expression
        if arg ∈ keys(model_SBML.species) && model_SBML.species[arg].rate_rule == true
            replace_with[i] = model_SBML.species[arg].formula
            continue
        end

        # Default case, use formula for given specie, and if specie is given in amount
        # Here it might happen that arg is scaled with compartment, e.g. S / C thus 
        # first the specie is extracted 
        arg = filter(x -> x ∉ ['(', ')'], arg)
        arg = occursin('/', arg) ? arg[1:findfirst(x -> x == '/', arg)-1] : arg
        arg = occursin('*', arg) ? arg[1:findfirst(x -> x == '*', arg)-1] : arg
        specie = model_SBML.species[arg]
        scale_with_compartment = specie.unit == :Amount && specie.only_substance_units == false
        if scale_with_compartment == true
            replace_with[i] = "(" * specie.formula * ") / " * specie.compartment
        else
            replace_with[i] = specie.formula
        end
    end

    formula_cp = deepcopy(formula)
    for i in eachindex(replace_with)
        formula = replace(formula, formula_cp[start_rateof[i]:end_rateof[i]] => replace_with[i])
    end

    formula = replace(formula, "<=" => "≤")
    formula = replace(formula, ">=" => "≥")

    return formula
end


function replace_reactionid!(model_SBML::ModelSBML)::Nothing

    for (specie_id, specie) in model_SBML.species
        for (reaction_id, reaction) in model_SBML.reactions
            specie.formula = replace_variable(specie.formula, reaction_id, reaction.kinetic_math)
        end
    end

    return nothing
end


"""
    is_number(x::String)::Bool

    Check if a string x is a number (Float) taking sciencetific notation into account.
"""
function is_number(x::AbstractString)::Bool
    re1 = r"^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)$" # Picks up scientific notation
    re2 = r"^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$"
    return (occursin(re1, x) || occursin(re2, x))
end
"""
    is_number(x::SubString{String})::Bool
"""
function is_number(x::SubString{String})::Bool
    re1 = r"^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)$" # Picks up scientific notation
    re2 = r"^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$"
    return (occursin(re1, x) || occursin(re2, x))
end


# For when exporting to ODESystem or ReactionSystem 
function get_specie_map(model_SBML::ModelSBML; reaction_system::Bool=false)::Tuple{String, String, String}

    if reaction_system == false
        _species_write = "\tModelingToolkit.@variables t "
    else
        _species_write = "\tModelingToolkit.@variables t\n\tsps = Catalyst.@species "
    end
    _species_write_array = "\tspecies = ["
    _specie_map_write = "\tspecie_map = [\n"
    
    # Identify which variables/parameters are dynamic 
    for specie_id in keys(model_SBML.species)
        _species_write *= specie_id * "(t) "
        _species_write_array *= specie_id * ", "
    end
    for (parameter_id, parameter) in model_SBML.parameters
        if parameter.constant == true
            continue
        end
        _species_write *= parameter_id * "(t) "
        _species_write_array *= parameter_id * ", "
    end
    for (compartment_id, compartment) in model_SBML.compartments
        if compartment.constant == true
            continue
        end
        _species_write *= compartment_id * "(t) "
        _species_write_array *= compartment_id * ", "
    end
    _species_write_array = _species_write_array[1:end-2] * "]" # Ensure correct valid syntax

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


    return _species_write, _species_write_array, _specie_map_write
end


# For when exporting to ODESystem or ReactionSystem 
function get_parameter_map(model_SBML::ModelSBML; reaction_system::Bool=false)::Tuple{String, String, String}

    if reaction_system == false
        _parameters_write = "\tModelingToolkit.@parameters "
    else
        _parameters_write = "\tps = Catalyst.@parameters "
    end
    _parameters_write_array = "\tparameters = ["
    _parameter_map_write = "\tparameter_map = [\n"
    
    for (parameter_id, parameter) in model_SBML.parameters
        if parameter.constant == false
            continue
        end
        # For ReactionSystem we carefully need to separate species and variables
        if reaction_system == true && parameter.assignment_rule == true
            continue
        end
        _parameters_write *= parameter_id * " "
        _parameters_write_array *= parameter_id * ", "
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
        _parameters_write_array *= compartment_id * ", "
    end
    # Special case where we do not have any parameters
    if length(_parameters_write) == 29 && _parameters_write[1:14] != "\tps = Catalyst"
        _parameters_write = ""
        _parameters_write_array *= "]"
    else
        _parameters_write_array = _parameters_write_array[1:end-2] * "]"
    end

    # Map setting initial values for parameters 
    for (parameter_id, parameter) in model_SBML.parameters
        if parameter.constant == false
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

    return _parameters_write, _parameters_write_array, _parameter_map_write
end