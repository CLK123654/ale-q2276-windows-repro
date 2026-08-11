function windows_verify(taskRoot, inputRoot, referenceRoot, implementationRoot, evidenceRoot)
arguments
    taskRoot (1,1) string
    inputRoot (1,1) string
    referenceRoot (1,1) string
    implementationRoot (1,1) string
    evidenceRoot (1,1) string
end

addpath(implementationRoot);
if isfolder(evidenceRoot)
    rmdir(evidenceRoot,"s");
end
mkdir(evidenceRoot);
tempRoot = string(tempname);
mkdir(tempRoot);
cleanup = onCleanup(@() removeTree(tempRoot));

expectedHashes = jsondecode(fileread(fullfile(taskRoot,"..","qa","expected_hashes.json")));
attachmentNames = ["输入数据包.zip","reference.zip","关键标准答案.xlsx","任务规格转化.xlsx"];
attachmentKeys = ["input","reference","answers","spec"];
attachments = struct();
for index = 1:numel(attachmentNames)
    file = fullfile(taskRoot,attachmentNames(index));
    actualHash = sha256(file);
    expectedHash = string(expectedHashes.(attachmentKeys(index)).sha256);
    assert(actualHash==expectedHash,"Attachment hash does not match the committed contract: %s",attachmentNames(index));
    key = "artifact_" + index;
    attachments.(key).name = attachmentNames(index);
    attachments.(key).sha256 = actualHash;
end
writeText(fullfile(evidenceRoot,"attachment-hashes.json"), ...
    string(jsonencode(attachments,PrettyPrint=true))+newline);

referenceFiles = relativeFiles(referenceRoot);
assert(numel(referenceFiles)==7,"Reference must contain seven declared business deliverables");
cleanRuns = struct([]);
for rootIndex = 1:2
    rootId = "clean-" + char('a'+rootIndex-1);
    root = fullfile(tempRoot,rootId);
    input = fullfile(root,"input");
    mkdir(input);
    copyfile(fullfile(inputRoot,"*"),input);
    before = treeHashes(input);
    runItems = struct([]);
    for runIndex = 1:2
        output = fullfile(root,"output-"+runIndex);
        assert(~isfolder(output),"Output directory was not empty before execution");
        run_cure_review(input,output);
        assertTreesEqual(output,referenceRoot);
        runItems(runIndex).run_id = runIndex;
        runItems(runIndex).return_code = 0;
        runItems(runIndex).output_started_empty = true;
        runItems(runIndex).reference_match = true;
        runItems(runIndex).generated_paths = relativeFiles(output);
    end
    assert(isequal(before,treeHashes(input)),"Task execution changed the input package");
    cleanRuns(rootIndex).root_id = rootId;
    cleanRuns(rootIndex).input_unchanged = true;
    cleanRuns(rootIndex).runs = runItems;
end

originalPrograms = readtable(fullfile(referenceRoot,"results","program_review.csv"),TextType="string");
originalP02 = originalPrograms(originalPrograms.program_id=="P02",:);
assert(height(originalP02)==1,"Reference does not contain one P02 row");

mutationInput = fullfile(tempRoot,"positive-input");
mutationOutput = fullfile(tempRoot,"positive-output");
mkdir(mutationInput);
copyfile(fullfile(inputRoot,"*"),mutationInput);
tariffPath = fullfile(mutationInput,"commercial","energy_tariff.csv");
tariff = readtable(tariffPath,TextType="string");
peak = tariff.band=="peak";
assert(sum(peak)==1,"Positive case requires one peak tariff interval");
tariff.tariff_yuan_kwh(peak) = tariff.tariff_yuan_kwh(peak)+0.20;
writetable(tariff,tariffPath);
run_cure_review(mutationInput,mutationOutput);
mutatedPrograms = readtable(fullfile(mutationOutput,"results","program_review.csv"),TextType="string");
mutatedP02 = mutatedPrograms(mutatedPrograms.program_id=="P02",:);
mutatedSummary = jsondecode(fileread(fullfile(mutationOutput,"results","review_summary.json")));
assert(height(mutatedP02)==1,"Positive case lost P02");
assert(string(mutatedSummary.program_selection.program_id)=="P02","Peak tariff change unexpectedly changed the released program");
assert(mutatedP02.cost_yuan>originalP02.cost_yuan+0.1,"Peak tariff change did not change the P02 business cost");
assert(abs(mutatedP02.energy_kwh-originalP02.energy_kwh)<1e-9,"Tariff-only change altered physical energy");
positive.name = "peak tariff increases by 0.20 yuan per kilowatt-hour";
positive.input_changed = true;
positive.behavior_changed = true;
positive.original_cost_yuan = originalP02.cost_yuan;
positive.mutated_cost_yuan = mutatedP02.cost_yuan;
positive.selected_program_id = char(string(mutatedSummary.program_selection.program_id));
positive.assertions_passed = true;
writeText(fullfile(evidenceRoot,"positive-case.json"), ...
    string(jsonencode(positive,PrettyPrint=true))+newline);

negativeInput = fullfile(tempRoot,"negative-input");
negativeOutput = fullfile(tempRoot,"negative-output");
mkdir(negativeInput);
copyfile(fullfile(inputRoot,"*"),negativeInput);
programPath = fullfile(negativeInput,"program_candidates.csv");
programs = readtable(programPath,TextType="string");
programs(end+1,:) = programs(1,:);
writetable(programs,programPath);
negativeFailed = false;
negativeMessage = "";
try
    run_cure_review(negativeInput,negativeOutput);
catch errorValue
    negativeFailed = true;
    negativeMessage = string(errorValue.identifier)+":"+string(errorValue.message);
end
if isfolder(negativeOutput)
    negativeArtifacts = relativeFiles(negativeOutput);
else
    negativeArtifacts = strings(0,1);
end
assert(negativeFailed && isempty(negativeArtifacts),"Duplicate program_id did not fail closed");
writeText(fullfile(evidenceRoot,"negative-case.log"),negativeMessage+newline);

summary.schema_version = 1;
summary.result = "PASS";
summary.task_id = "2276";
summary.task_slug = "autoclave_cure_release_review";
summary.runner.os = getenv("RUNNER_OS");
summary.runner.image_os = getenv("ImageOS");
summary.runner.architecture = computer("arch");
summary.commit_sha = getenv("GITHUB_SHA");
summary.workflow_run_id = str2double(getenv("GITHUB_RUN_ID"));
summary.primary_software.name = "MATLAB";
summary.primary_software.version = version;
summary.primary_software.executed = true;
summary.command = "run_cure_review(inputRoot,outputRoot)";
summary.attachments = attachments;
summary.generated_paths = referenceFiles;
summary.clean_directory_count = 2;
summary.process_runs_per_directory = 2;
summary.clean_runs = cleanRuns;
summary.positive_mutation = positive;
summary.negative_case.name = "program_candidates.csv contains a duplicate program_id";
summary.negative_case.return_code = 1;
summary.negative_case.failed_closed = true;
summary.negative_case.no_stale_deliverables = true;
summary.reference_match = true;
writeText(fullfile(evidenceRoot,"windows-summary.json"), ...
    string(jsonencode(summary,PrettyPrint=true))+newline);
end

function files = relativeFiles(root)
items = dir(fullfile(root,"**","*"));
items = items(~[items.isdir]);
files = strings(numel(items),1);
prefix = string(root)+filesep;
for index = 1:numel(items)
    full = string(fullfile(items(index).folder,items(index).name));
    files(index) = replace(extractAfter(full,strlength(prefix)),"\","/");
end
files = sort(files);
end

function hashes = treeHashes(root)
files = relativeFiles(root);
hashes = strings(numel(files),2);
for index = 1:numel(files)
    hashes(index,1) = files(index);
    hashes(index,2) = sha256(fullfile(root,files(index)));
end
end

function assertTreesEqual(actual,expected)
actualFiles = relativeFiles(actual);
expectedFiles = relativeFiles(expected);
assert(isequal(actualFiles,expectedFiles),"Generated file set differs from Reference");
for index = 1:numel(expectedFiles)
    actualFile = fullfile(actual,expectedFiles(index));
    expectedFile = fullfile(expected,expectedFiles(index));
    [~,~,extension] = fileparts(expectedFiles(index));
    extension = lower(string(extension));
    if extension==".png"
        [leftImage,leftMap,leftAlpha] = imread(actualFile);
        [rightImage,rightMap,rightAlpha] = imread(expectedFile);
        assert(isequal(leftImage,rightImage) && isequal(leftMap,rightMap) && isequal(leftAlpha,rightAlpha), ...
            "Generated image pixels differ from Reference: %s",expectedFiles(index));
    elseif extension==".mat"
        left = load(actualFile);
        right = load(expectedFile);
        assert(isequaln(left,right),"Generated MAT variables differ from Reference: %s",expectedFiles(index));
    else
        assert(isequal(readBytes(actualFile),readBytes(expectedFile)), ...
            "Generated file differs from Reference: %s",expectedFiles(index));
    end
end
end

function bytes = readBytes(file)
handle = fopen(file,"rb");
assert(handle>=0,"Unable to read file: %s",file);
cleaner = onCleanup(@() fclose(handle));
bytes = fread(handle,Inf,"*uint8");
end

function hash = sha256(file)
bytes = readBytes(file);
digest = java.security.MessageDigest.getInstance("SHA-256");
digest.update(typecast(bytes,"int8"));
raw = typecast(digest.digest(),"uint8");
hash = string(lower(reshape(dec2hex(raw,2).',1,[])));
end

function writeText(file,value)
handle = fopen(file,"w","n","UTF-8");
assert(handle>=0,"Unable to write evidence file");
cleaner = onCleanup(@() fclose(handle));
fprintf(handle,"%s",char(value));
end

function removeTree(root)
if isfolder(root)
    try
        rmdir(root,"s");
    catch
    end
end
end
