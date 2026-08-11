function run_cure_review(inputRoot, outputRoot)
arguments
    inputRoot (1,1) string
    outputRoot (1,1) string
end

[runA, runB, models, programs, tariff, laminate, criteria] = loadAndValidate(inputRoot);

if isfolder(outputRoot)
    rmdir(outputRoot,"s");
end
mkdir(fullfile(outputRoot,"results"));
mkdir(fullfile(outputRoot,"figures"));
mkdir(fullfile(outputRoot,"src"));

[calibrationReview, modelScores, selectedModel, fittedA, fittedB] = ...
    reviewModels(runA, runB, models, criteria);
[programReview, profiles] = reviewPrograms(programs, selectedModel, tariff, laminate, criteria);

feasible = programReview(programReview.feasible,:);
assert(~isempty(feasible),"No production program satisfies the supplied process criteria");
feasible = sortrows(feasible,{"cost_yuan","energy_kwh","cycle_min","program_id"});
selectedId = feasible.program_id(1);
selectedProgram = programReview(programReview.program_id==selectedId,:);
selectedProfile = profiles.(matlab.lang.makeValidName(selectedId));

writetable(calibrationReview,fullfile(outputRoot,"results","calibration_review.csv"));
writetable(programReview,fullfile(outputRoot,"results","program_review.csv"));
writetable(selectedProfile,fullfile(outputRoot,"results","selected_profile.csv"));

summary = buildSummary(runA,runB,models,programs,programReview,selectedModel,selectedProgram,criteria);
fid = fopen(fullfile(outputRoot,"results","review_summary.json"),"w");
assert(fid>0,"Unable to create review_summary.json");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid,"%s\n",jsonencode(summary,PrettyPrint=true));
clear cleanup

save(fullfile(outputRoot,"results","cure_review.mat"), ...
    "calibrationReview","modelScores","programReview","selectedProfile", ...
    "selectedModel","selectedProgram","summary","-v7");

createReviewFigure(runA,runB,fittedA,fittedB,programReview,selectedProfile, ...
    fullfile(outputRoot,"figures","cure_review.png"));
copyfile(mfilename("fullpath"),fullfile(outputRoot,"src","run_cure_review.m"));
end

function [runA,runB,models,programs,tariff,laminate,criteria] = loadAndValidate(inputRoot)
runA = readtable(fullfile(inputRoot,"calibration","run_A.csv"),TextType="string");
runB = readtable(fullfile(inputRoot,"calibration","run_B.csv"),TextType="string");
models = readtable(fullfile(inputRoot,"model_candidates.csv"),TextType="string");
programs = readtable(fullfile(inputRoot,"program_candidates.csv"),TextType="string");
tariff = readtable(fullfile(inputRoot,"commercial","energy_tariff.csv"),TextType="string");
laminate = jsondecode(fileread(fullfile(inputRoot,"production","laminate_profile.json")));
criteria = jsondecode(fileread(fullfile(inputRoot,"rules","process_criteria.json")));

requireColumns(runA,["run_id","time_s","air_temp_c","part_temp_c","heat_flow_w_kg"],"run_A.csv");
requireColumns(runB,["run_id","time_s","air_temp_c","part_temp_c","heat_flow_w_kg"],"run_B.csv");
requireColumns(models,["model_id","tau_s","A_s_1","Ea_j_mol","reaction_order_n","beta_c_per_alpha"],"model_candidates.csv");
requireColumns(programs,["program_id","ramp_rate_c_min","hold_temp_c","hold_min","cooldown_rate_c_min"],"program_candidates.csv");
requireColumns(tariff,["start_min","end_min","tariff_yuan_kwh","band"],"energy_tariff.csv");

assert(height(runA)>=3 && height(runB)>=3,"Calibration runs require at least three observations");
assert(runA.time_s(1)==0 && runB.time_s(1)==0,"Calibration runs must start at zero seconds");
assert(all(diff(runA.time_s)>0) && all(diff(runB.time_s)>0),"Calibration times must increase strictly");
assert(all(string(runA.run_id)=="A") && all(string(runB.run_id)=="B"),"Calibration run identifiers do not match their files");
assert(all(isfinite(runA{:,2:5}),"all") && all(isfinite(runB{:,2:5}),"all"),"Calibration observations must be finite");

models.model_id = string(models.model_id);
programs.program_id = string(programs.program_id);
assert(~isempty(models) && numel(unique(models.model_id))==height(models),"Model identifiers must be present and unique");
assert(~isempty(programs) && numel(unique(programs.program_id))==height(programs),"Program identifiers must be present and unique");
assert(all(models{:,2:6}>0,"all"),"Model parameters must be positive");
assert(all(programs.ramp_rate_c_min>0) && all(programs.hold_temp_c>criteria.energy_model.ambient_c),"Program heating values are invalid");
assert(all(programs.hold_min>0) && all(programs.cooldown_rate_c_min<0),"Program hold and cooling values are invalid");

tariff = sortrows(tariff,"start_min");
assert(tariff.start_min(1)==0,"Tariff schedule must start at zero minutes");
assert(all(tariff.end_min>tariff.start_min),"Tariff intervals must have positive duration");
assert(all(abs(tariff.start_min(2:end)-tariff.end_min(1:end-1))<1e-12),"Tariff intervals must be contiguous");
assert(all(tariff.tariff_yuan_kwh>=0),"Tariffs cannot be negative");
assert(laminate.initial_part_temp_c==criteria.initial_state.part_temp_c, ...
    "Laminate and criteria initial temperatures differ");
assert(laminate.initial_cure_degree==criteria.initial_state.cure_degree, ...
    "Laminate and criteria initial cure values differ");
assert(laminate.tau_multiplier>0,"Laminate thermal inertia multiplier must be positive");
assert(criteria.solver.max_step_s>0 && criteria.program.profile_interval_s>0,"Solver and profile intervals must be positive");

maxCycle = max((programs.hold_temp_c-criteria.energy_model.ambient_c)./programs.ramp_rate_c_min + ...
    programs.hold_min + (programs.hold_temp_c-criteria.program.cool_end_c)./abs(programs.cooldown_rate_c_min));
assert(tariff.end_min(end)>=maxCycle,"Tariff schedule does not cover every supplied program");
end

function requireColumns(tableValue, expected, fileName)
actual = string(tableValue.Properties.VariableNames);
assert(isequal(actual,expected),"Unexpected columns in %s",fileName);
end

function [review,modelScores,selectedModel,fittedA,fittedB] = reviewModels(runA,runB,models,criteria)
review = table();
modelScores = table();
fittedByModel = struct();
for i = 1:height(models)
    p = models(i,:);
    [metricsA,predA] = calibrationMetrics(runA,p,criteria);
    [metricsB,predB] = calibrationMetrics(runB,p,criteria);
    totalScore = metricsA.normalized_component + metricsB.normalized_component;
    rows = [makeCalibrationRow(p,"A",metricsA,totalScore); ...
            makeCalibrationRow(p,"B",metricsB,totalScore)];
    review = [review;rows]; %#ok<AGROW>
    modelScores = [modelScores;table(p.model_id,totalScore, ...
        'VariableNames',{'model_id','total_score'})]; %#ok<AGROW>
    fittedByModel.(matlab.lang.makeValidName(p.model_id)) = {predA,predB};
end
modelScores = sortrows(modelScores,{"total_score","model_id"});
selectedId = modelScores.model_id(1);
selectedModel = models(models.model_id==selectedId,:);
review.selected_model = review.model_id==selectedId;
review = movevars(review,"selected_model","After","model_id");
review.temperature_rmse_c = round(review.temperature_rmse_c,criteria.rounding.rmse);
review.heat_flow_rmse_w_kg = round(review.heat_flow_rmse_w_kg,criteria.rounding.rmse);
review.normalized_component = round(review.normalized_component,criteria.rounding.rmse);
review.total_score = round(review.total_score,criteria.rounding.rmse);
selectedPredictions = fittedByModel.(matlab.lang.makeValidName(selectedId));
fittedA = selectedPredictions{1};
fittedB = selectedPredictions{2};
end

function row = makeCalibrationRow(p,runId,metrics,totalScore)
row = table(p.model_id,runId,p.tau_s,p.A_s_1,p.Ea_j_mol,p.reaction_order_n, ...
    p.beta_c_per_alpha,metrics.samples,metrics.temperature_rmse_c, ...
    metrics.heat_flow_rmse_w_kg,metrics.normalized_component,totalScore, ...
    'VariableNames',{'model_id','run_id','tau_s','A_s_1','Ea_j_mol', ...
    'reaction_order_n','beta_c_per_alpha','samples','temperature_rmse_c', ...
    'heat_flow_rmse_w_kg','normalized_component','total_score'});
end

function [metrics,predicted] = calibrationMetrics(observed,p,criteria)
t = observed.time_s;
y0 = [criteria.initial_state.part_temp_c;criteria.initial_state.cure_degree];
opts = odeset('RelTol',criteria.solver.relative_tolerance, ...
    'AbsTol',[criteria.solver.absolute_tolerance criteria.solver.absolute_tolerance], ...
    'MaxStep',criteria.solver.max_step_s);
rhs = @(time,state) stateDerivative(time,state,p,1,criteria, ...
    @(queryTime) interp1(t,observed.air_temp_c,queryTime,"linear"));
[~,state] = ode45(rhs,t,y0,opts);
rate = cureRate(state(:,1),state(:,2),p,criteria);
predicted = table(t,state(:,1),criteria.physical_constants.reaction_enthalpy_j_kg*rate, ...
    'VariableNames',{'time_s','part_temp_c','heat_flow_w_kg'});
metrics.samples = height(observed);
metrics.temperature_rmse_c = sqrt(mean((predicted.part_temp_c-observed.part_temp_c).^2));
metrics.heat_flow_rmse_w_kg = sqrt(mean((predicted.heat_flow_w_kg-observed.heat_flow_w_kg).^2));
metrics.normalized_component = ...
    (metrics.temperature_rmse_c/criteria.calibration.temperature_resolution_c)^2 + ...
    (metrics.heat_flow_rmse_w_kg/criteria.calibration.heat_flow_resolution_w_kg)^2;
end

function [review,profiles] = reviewPrograms(programs,p,tariff,laminate,criteria)
review = table();
profiles = struct();
for i = 1:height(programs)
    [row,profile] = evaluateProgram(programs(i,:),p,tariff,laminate,criteria);
    review = [review;row]; %#ok<AGROW>
    profiles.(matlab.lang.makeValidName(programs.program_id(i))) = profile;
end
review = sortrows(review,"program_id");
end

function [row,profile] = evaluateProgram(program,p,tariff,laminate,criteria)
ambient = criteria.energy_model.ambient_c;
rampEndMin = (program.hold_temp_c-ambient)/program.ramp_rate_c_min;
coolStartMin = rampEndMin+program.hold_min;
cycleMin = coolStartMin+(program.hold_temp_c-criteria.program.cool_end_c)/abs(program.cooldown_rate_c_min);
cycleS = cycleMin*60;
dt = criteria.solver.max_step_s;
tGrid = unique([0:dt:cycleS cycleS]);
y0 = [laminate.initial_part_temp_c;laminate.initial_cure_degree];
opts = odeset('RelTol',criteria.solver.relative_tolerance, ...
    'AbsTol',[criteria.solver.absolute_tolerance criteria.solver.absolute_tolerance], ...
    'MaxStep',dt);
airFunction = @(queryTime) programAir(queryTime/60,program,criteria);
rhs = @(time,state) stateDerivative(time,state,p,laminate.tau_multiplier,criteria,airFunction);
[t,state] = ode45(rhs,tGrid,y0,opts);
air = arrayfun(airFunction,t);
stage = programStage(t/60,program,criteria);

peak = max(state(:,1));
beforeCool = t<=coolStartMin*60+1e-9;
ramp = t<=rampEndMin*60+1e-9;
maxPositiveDelta = max(state(beforeCool,1)-air(beforeCool));
maxRampLag = max(air(ramp)-state(ramp,1));
alphaAtCool = interp1(t,state(:,2),coolStartMin*60,"linear");
finalCure = state(end,2);

dair = zeros(size(t));
dair(stage=="RAMP") = program.ramp_rate_c_min;
dair(stage=="COOL") = program.cooldown_rate_c_min;
power = max(0,criteria.energy_model.base_kw + ...
    criteria.energy_model.temperature_kw_per_c*(air-ambient) + ...
    criteria.energy_model.positive_ramp_kw_per_c_min*max(dair,0));
stepHours = diff(t)/3600;
stepEnergy = power(1:end-1).*stepHours;
stepTariff = tariffAt(t(1:end-1)/60,tariff);
stepCost = stepEnergy.*stepTariff;
energy = sum(stepEnergy);
cost = sum(stepCost);

failures = strings(0,1);
c = criteria.constraints;
if finalCure<c.final_cure_degree_min, failures(end+1)="FINAL_CURE"; end
if alphaAtCool<c.cure_degree_at_cool_start_min, failures(end+1)="COOL_START_CURE"; end
if peak>c.peak_part_temp_c_max, failures(end+1)="PEAK_TEMP"; end
if maxPositiveDelta>c.max_positive_part_minus_air_c_before_cool_max, failures(end+1)="EXOTHERM_DELTA"; end
if maxRampLag>c.max_air_minus_part_c_during_ramp_max, failures(end+1)="RAMP_LAG"; end
if cycleMin>c.cycle_min_max, failures(end+1)="CYCLE_TIME"; end
failureCodes = "NONE";
if ~isempty(failures), failureCodes = join(failures,"|"); end

row = table(program.program_id,program.ramp_rate_c_min,program.hold_temp_c,program.hold_min, ...
    program.cooldown_rate_c_min,round(cycleMin,criteria.rounding.cycle_min), ...
    round(finalCure,criteria.rounding.cure_degree),round(alphaAtCool,criteria.rounding.cure_degree), ...
    round(peak,criteria.rounding.temperature_c),round(maxPositiveDelta,criteria.rounding.temperature_c), ...
    round(maxRampLag,criteria.rounding.temperature_c),round(energy,criteria.rounding.energy_kwh), ...
    round(cost,criteria.rounding.cost_yuan),isempty(failures),failureCodes, ...
    'VariableNames',{'program_id','ramp_rate_c_min','hold_temp_c','hold_min', ...
    'cooldown_rate_c_min','cycle_min','final_cure_degree','cure_degree_at_cool_start', ...
    'peak_part_temp_c','max_positive_part_minus_air_c_before_cool', ...
    'max_air_minus_part_c_during_ramp','energy_kwh','cost_yuan','feasible','failure_codes'});

profileTimes = unique([0:criteria.program.profile_interval_s:cycleS cycleS])';
profileAir = interp1(t,air,profileTimes,"linear");
profilePart = interp1(t,state(:,1),profileTimes,"linear");
profileCure = interp1(t,state(:,2),profileTimes,"linear");
profileStage = programStage(profileTimes/60,program,criteria);
profileTariff = tariffAt(profileTimes/60,tariff);
profileEnergy = zeros(size(profileTimes));
profileCost = zeros(size(profileTimes));
for k = 2:numel(profileTimes)
    use = t(1:end-1)>=profileTimes(k-1)-1e-9 & t(1:end-1)<profileTimes(k)-1e-9;
    profileEnergy(k) = sum(stepEnergy(use));
    profileCost(k) = sum(stepCost(use));
end
profile = table(round(profileTimes/60,criteria.rounding.cycle_min),profileStage, ...
    round(profileAir,criteria.rounding.temperature_c),round(profilePart,criteria.rounding.temperature_c), ...
    round(profileCure,criteria.rounding.cure_degree),profileTariff, ...
    round(profileEnergy,criteria.rounding.energy_kwh),round(profileCost,criteria.rounding.cost_yuan), ...
    'VariableNames',{'elapsed_min','stage','air_setpoint_c','part_temp_c','cure_degree', ...
    'tariff_yuan_kwh','energy_kwh_interval','cost_yuan_interval'});

energyGap = row.energy_kwh-sum(profile.energy_kwh_interval);
costGap = row.cost_yuan-sum(profile.cost_yuan_interval);
profile.energy_kwh_interval(end) = round(profile.energy_kwh_interval(end)+energyGap,criteria.rounding.energy_kwh);
profile.cost_yuan_interval(end) = round(profile.cost_yuan_interval(end)+costGap,criteria.rounding.cost_yuan);
end

function derivative = stateDerivative(time,state,p,tauMultiplier,criteria,airFunction)
air = airFunction(time);
rate = cureRate(state(1),state(2),p,criteria);
derivative = [(air-state(1))/(p.tau_s*tauMultiplier)+p.beta_c_per_alpha*rate;rate];
end

function rate = cureRate(partTemp,cureDegree,p,criteria)
alpha = min(0.999999999,max(0,cureDegree));
rate = p.A_s_1.*exp(-p.Ea_j_mol./(criteria.physical_constants.gas_constant_j_mol_k.*(partTemp+273.15))).* ...
    (1-alpha).^p.reaction_order_n;
end

function air = programAir(minute,program,criteria)
ambient = criteria.energy_model.ambient_c;
rampEnd = (program.hold_temp_c-ambient)/program.ramp_rate_c_min;
coolStart = rampEnd+program.hold_min;
if minute<=rampEnd
    air = ambient+program.ramp_rate_c_min*minute;
elseif minute<=coolStart
    air = program.hold_temp_c;
else
    air = max(criteria.program.cool_end_c,program.hold_temp_c+program.cooldown_rate_c_min*(minute-coolStart));
end
end

function stage = programStage(minutes,program,criteria)
ambient = criteria.energy_model.ambient_c;
rampEnd = (program.hold_temp_c-ambient)/program.ramp_rate_c_min;
coolStart = rampEnd+program.hold_min;
stage = repmat("HOLD",size(minutes));
stage(minutes<=rampEnd+1e-9) = "RAMP";
stage(minutes>coolStart+1e-9) = "COOL";
end

function values = tariffAt(minutes,tariff)
values = zeros(size(minutes));
for i = 1:numel(minutes)
    row = find(minutes(i)>=tariff.start_min & minutes(i)<tariff.end_min,1);
    if isempty(row) && abs(minutes(i)-tariff.end_min(end))<1e-9
        row = height(tariff);
    end
    assert(~isempty(row),"Tariff schedule does not cover the program timeline");
    values(i) = tariff.tariff_yuan_kwh(row);
end
end

function summary = buildSummary(runA,runB,models,programs,programReview,selectedModel,selectedProgram,criteria)
summary.criteria_version = criteria.criteria_version;
summary.input_counts.calibration_run_A_rows = height(runA);
summary.input_counts.calibration_run_B_rows = height(runB);
summary.input_counts.model_candidates = height(models);
summary.input_counts.program_candidates = height(programs);
summary.model_selection.model_id = char(selectedModel.model_id);
summary.model_selection.tau_s = selectedModel.tau_s;
summary.model_selection.A_s_1 = selectedModel.A_s_1;
summary.model_selection.Ea_j_mol = selectedModel.Ea_j_mol;
summary.model_selection.reaction_order_n = selectedModel.reaction_order_n;
summary.model_selection.beta_c_per_alpha = selectedModel.beta_c_per_alpha;
summary.program_selection.program_id = char(selectedProgram.program_id);
summary.program_selection.cycle_min = selectedProgram.cycle_min;
summary.program_selection.energy_kwh = selectedProgram.energy_kwh;
summary.program_selection.cost_yuan = selectedProgram.cost_yuan;
summary.program_selection.final_cure_degree = selectedProgram.final_cure_degree;
summary.program_selection.peak_part_temp_c = selectedProgram.peak_part_temp_c;
summary.program_selection.feasible_programs = sum(programReview.feasible);
end

function createReviewFigure(runA,runB,fittedA,fittedB,programReview,profile,path)
figure('Visible','off','Position',[100 100 1200 820]);
tiledlayout(2,2,'TileSpacing','compact','Padding','compact');
nexttile;
plot(runA.time_s/60,runA.part_temp_c,'Color',[0.10 0.40 0.75],LineWidth=1.4); hold on;
plot(fittedA.time_s/60,fittedA.part_temp_c,'--','Color',[0.80 0.25 0.15],LineWidth=1.4);
xlabel('Time min'); ylabel('Part temperature C'); title('Calibration run A'); grid on;
legend('Observed','Selected model',Location='best');
nexttile;
plot(runB.time_s/60,runB.part_temp_c,'Color',[0.10 0.40 0.75],LineWidth=1.4); hold on;
plot(fittedB.time_s/60,fittedB.part_temp_c,'--','Color',[0.80 0.25 0.15],LineWidth=1.4);
xlabel('Time min'); ylabel('Part temperature C'); title('Calibration run B'); grid on;
legend('Observed','Selected model',Location='best');
nexttile;
yyaxis left;
plot(profile.elapsed_min,profile.air_setpoint_c,LineWidth=1.4); hold on;
plot(profile.elapsed_min,profile.part_temp_c,LineWidth=1.4);
ylabel('Temperature C');
yyaxis right;
plot(profile.elapsed_min,profile.cure_degree,LineWidth=1.4);
ylabel('Cure degree'); xlabel('Elapsed time min'); title('Released production program'); grid on;
legend('Air','Part','Cure degree',Location='best');
nexttile;
positions = (1:height(programReview))';
bar(positions,programReview.cost_yuan,'FaceColor',[0.45 0.62 0.80]); hold on;
bad = ~programReview.feasible;
scatter(positions(bad),programReview.cost_yuan(bad),45,[0.80 0.20 0.15],'filled');
xticks(positions); xticklabels(programReview.program_id);
xlabel('Program'); ylabel('Cost yuan'); title('Program review'); grid on;
exportgraphics(gcf,path,Resolution=160);
close(gcf);
end
