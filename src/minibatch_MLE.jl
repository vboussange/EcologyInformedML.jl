# for more intuition on kwargs : https://discourse.julialang.org/t/passing-kwargs-can-overwrite-other-keyword-arguments/74933

"""
$(SIGNATURES)

default loss function for `minibatch_MLE`.
"""
function _loss_multiple_shoot_init(data, pred, ic_term)
    l =  mean((data - pred).^2)
    l +=  mean((data[:,1] - pred[:,1]).^2) * ic_term # putting more weights on initial conditions
    return l
end

"""
$(SIGNATURES)

Maximum likelihood estimation with minibatching. Loops through ADAM and BFGS.
Returns `minloss, p_trained, ranges, losses, θs`.

# arguments
- p_init : initial guess for parameters of `prob`
- group_size : size of segments
- data_set : data
- prob : ODE problem for the state variables.
- tsteps : corresponding to data
- alg : ODE solver
- sensealg : sensitivity solver

# optional
- `loss_fn` : the loss function, that takes as arguments `loss_fn(data, pred, ic_term)` where 
    `data` is the training data and `pred` corresponds to the predicted state variables. 
    `loss_fn` must transform the pred into the observables, with a function 
    `h` that maps the state variables to the observables. By default, `h` is taken as the identity.
- `u0_init` : if not provided, we initialise from `data_set`
- `loss_fn` : loss function with arguments `loss_fn(data, pred, ic_term)`
- `λ` : dictionary with learning rates. `Dict("ADAM" => 0.01, "BFGS" => 0.01)`
- `maxiters` : dictionary with maximum iterations. Dict("ADAM" => 2000, "BFGS" => 1000),
- `continuity_term` : weight on continuity conditions
- `ic_term` : weight on initial conditions
- `verbose` : displaying loss
- `info_per_its` = 50,
- `plotting` : plotting convergence loss
- `info_per_its` = 50,
- `cb` : call back function.
    Must be of the form `cb(θs, p_trained, losses, pred, ranges)`
- `p_true` : true params
- `p_labs` : labels of the true parameters
- `threshold` : default to 1e-6
"""
function minibatch_MLE(;group_size::Int,  kwargs...)
    datasize = size(kwargs[:data_set],2)
    _minibatch_MLE(;ranges=_get_ranges(group_size, datasize),  kwargs...)
end

"""
$(SIGNATURES)

Similar to `minibatch_MLE` but for independent time series, where `data_set`
is a vector containing the independent arrays corresponding to the time series,
and `tsteps` is a vector where each entry contains the time steps
of the corresponding time series.
"""
function minibatch_ML_indep_TS(;group_size::Int,
                                data_set::Vector, #many different initial conditions
                                tsteps::Vector, #corresponding time steps
                                kwargs...)
    @assert length(tsteps) == length(data_set) "Independent time series must be gathered as a Vector"

    datasize_arr = size.(data_set,2)
    ranges_arr = [_get_ranges(group_size, datasize_arr[i]) for i in 1:length(data_set)]
    # updating to take into account the shift provoked by concatenating independent TS
    ranges_shift = cumsum(datasize_arr) # shift
    for i in 2:length(ranges_arr)
        for j in 1:length(ranges_arr[i]) # looping through rng in each independent TS
            ranges_arr[i][j] = ranges_shift[i-1] .+ ranges_arr[i][j] #adding shift to the start of the range
        end
    end
    data_set_cat = cat(data_set...,dims=2)
    ranges_cat = vcat(ranges_arr...)
    tsteps_cat = vcat(tsteps...)

    res = _minibatch_MLE(;ranges=ranges_cat,
        data_set=data_set_cat, 
        tsteps=tsteps_cat, 
        kwargs...,
        continuity_term = 0.,)  # this overrides kwargs, essential as it does not make sense to have continuity across indepdenent TS
        # NOTE: we could have continuity within a time series, this must be carefully thought out.
    # group back the time series in vector, to have
    # pred = [ [mibibatch_1_ts_1, mibibatch_2_ts_1...],  [mibibatch_1_ts_2, mibibatch_2_ts_2...] ...]
    pred_arr = [Array{eltype(data_set[1])}[] for _ in 1:length(data_set)]
    idx_res = [0;cumsum(length.(ranges_arr))]
    [pred_arr[i] = res.pred[idx_res[i]+1:idx_res[i+1]] for i in 1:length(data_set)]

    # reconstructing the problem with original format
    ranges_arr = [_get_ranges(group_size, datasize_arr[i]) for i in 1:length(data_set)]

    res_arr = ResultMLE(res.minloss, res.p_trained, res.p_true, res.p_labs, pred_arr, ranges_arr, res.losses, res.θs)
    return res_arr
end

function _minibatch_MLE(;p_init, 
                        u0s_init = nothing, # provided by iterative_minibatch_MLE
                        ranges, # provided by minibatch_MLE
                        data_set, 
                        prob, 
                        tsteps, 
                        alg, 
                        sensealg,
                        loss_fn = _loss_multiple_shoot_init,
                        optimizers = [ADAM(0.01), BFGS(initial_stepnorm=0.01)],
                        maxiters = [1000, 200],
                        continuity_term = 1.,
                        ic_term = 1.,
                        verbose = true,
                        plotting = false,
                        info_per_its=50,
                        cb = nothing,
                        p_true = nothing,
                        p_labs = nothing,
                        threshold = 1e-16,
                        )
    dim_prob = length(prob.u0) #used by loss_nm
    @assert length(optimizers) == length(maxiters)

    # minibatch loss
    function loss_mb(θ)
        return minibatch_loss(θ, 
                            data_set, 
                            tsteps, 
                            prob, 
                            (data, pred) -> loss_fn(data, pred, ic_term),
                            alg, 
                            ranges, 
                            continuity_term = continuity_term, 
                            sensealg = sensealg)
    end

    # normal loss
    function loss_nm(θ)
        params = @view θ[dim_prob + 1: end] # params of the problem
        u0_i = abs.(θ[1:dim_prob])
        prob_i = remake(prob; p=params, tspan=(tsteps[1], tsteps[end]), u0=u0_i)
        sol = solve(prob_i, alg, saveat = tsteps, sensealg = sensealg, kwargshandle=KeywordArgError)
        sol.retcode == :Success ? nothing : return Inf, []
        pred = sol |> Array
        l = loss_fn(data_set, pred, ic_term)
        return l, [pred]
    end

    if length(ranges) > 1
        # minibatching
        _loss = loss_mb
    else
        # normal MLE with initial estimation
        _loss = loss_nm
    end

    # initialising with data_set if not provided
    if isnothing(u0s_init) 
        @assert (size(data_set,1) == dim_prob) "The dimension of the training data does not correspond to the dimension of the state variables. This probably means that the training data corresponds to observables different from the state variables. In this case, you need to provide manually `u0s_init`." 
        u0s_init = reshape(data_set[:,first.(ranges),:],:)
    end
    # making sure that u0s_init are positive, otherwise we might have some numerical difficulties
    u0s_init[u0s_init .< 0.] .= 1e-3 # alternative formulation : `u0s_init = max.(u0s_init,1e-3)`
    θ = [u0s_init;p_init]
    nb_group = length(ranges)
    println("minibatch_MLE with $(length(tsteps)) points and $nb_group groups.")

    callback(θ, l, pred) = begin
        push!(losses, l)
        p_trained = @view θ[nb_group * dim_prob + 1: end]
        isnothing(p_true) ? nothing : push!(θs, sum((p_trained .- p_true).^2))
        if length(losses)%info_per_its==0
            verbose ? println("Current loss after $(length(losses)) iterations: $(losses[end])") : nothing
            if !isnothing(cb)
                cb(θs, p_trained, losses, pred, ranges)
            end
            if plotting
                plot_convergence(losses, 
                                pred, 
                                data_set, 
                                ranges, 
                                tsteps, 
                                p_true = p_true, 
                                p_labs = p_labs, 
                                θs = θs, 
                                p_trained = p_trained)
            end
        end
        if l < threshold
            println("❤ Threshold met ❤")
            return true
        else
            return false
        end
    end

    ################
    ### TRAINING ###
    ################
    # Container to track the losses
    losses = Float64[]
    # Container to track the parameter evolutions
    θs = Float64[]


    println("***************\nTraining started\n***************")
    opt = first(optimizers)
    println("Running optimizer $(typeof(opt))")
    res = DiffEqFlux.sciml_train(_loss, θ, opt, cb=callback, maxiters = first(maxiters))
    for(i, opt) in enumerate(optimizers[2:end])
        println("Running optimizer $(typeof(opt))")
        res =  DiffEqFlux.sciml_train(_loss, res.minimizer, opt, cb=callback, maxiters = maxiters[i+1])
    end
    minloss, pred = _loss(res.minimizer)
    p_trained = res.minimizer[dim_prob * nb_group + 1 : end]
    println("Minimum loss: $minloss")
    return ResultMLE(minloss, p_trained, p_true, p_labs, pred, ranges, losses, θs)
end

function _get_ranges(group_size, datasize)
    if group_size-1 < datasize
        ranges = DiffEqFlux.group_ranges(datasize, group_size)
        # minibatching
    else
        ranges = [1:datasize]
        # normal MLE with initial estimation
    end
    return ranges
end


"""
$(SIGNATURES)

Performs a iterative minibatch MLE, iterating over `group_sizes`. 
Stops the iteration when loss function increases between two iterations.

Returns an array with all `ResultMLE` obtained during the iteration.
For kwargs, see `minibatch_MLE`.

# Note 
- for now, does not support independent time series (`minibatch_ML_indep_TS`).
- at every iteration, initial conditions are initialised given the predition of previous iterations

# Specific arguments
- `group_sizes` : array of group sizes to test
- `optimizers_array`: optimizers_array[i] is an array of optimizers for the trainging processe of `group_sizes[i`
"""
function iterative_minibatch_MLE(;group_sizes,
                                optimizers_array,
                                threshold = 1e-16,
                                kwargs...)

    @assert length(group_sizes) == length(optimizers_array)

    # initialising results
    data_set = kwargs[:data_set]
    datasize = size(data_set,2)
    res = ResultMLE(Inf, [], [], [], [data_set], [1:datasize], [], [])
    res_array = ResultMLE[]
    for (i,gs) in enumerate(group_sizes)
        println("***************\nIterative training with group size $gs\n***************")
        ranges = _get_ranges(group_sizes[i], datasize)
        u0s_init = _initialise_u0s_iterative_minibatch_ML(res.pred,res.ranges,ranges)
        tempres = _minibatch_MLE(;ranges = ranges, 
                                optimizers = optimizers_array[i],
                                u0s_init = reshape(u0s_init,:),
                                threshold = threshold,
                                kwargs...)
        if tempres.minloss < res.minloss || tempres.minloss < threshold # if threshold is met, we can go one level above
            push!(res_array, tempres)
            res = tempres
        else
            break
        end
    end
    return res_array
end

function _initialise_u0s_iterative_minibatch_ML(pred, ranges_pred, ranges_2)
    dim_prob = size(first(pred),1)
    u0_2 = zeros(eltype(first(pred)), dim_prob, length(ranges_2))
    for (i, rng2) in enumerate(ranges_2)
        _r = first(rng2) # index of new initial condtions on the time steps
        for j in 0:length(ranges_pred)-1
            #=
            NOTE : here we traverse ranges_pred in descending order, to handle overlaps in ranges.
            Indeed, suppose we go in asending order.
            if _r == last(rng), it also means that _r == first(next rng),
            and in this case pred(first(next rng)) estimate is more accurate (all pred in the range depend on its value).
            =#
            rng = ranges_pred[end-j]
            if _r in rng
                ui_pred = reshape(pred[end-j][:, _r .== rng],:)
                u0_2[:,i] .= ui_pred
                break
            end
        end
    end
    return u0_2
end