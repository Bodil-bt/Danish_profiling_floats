function export_data(varargin)
%EXPORT_DATA  Build float-site/data.js from the pipeline's saved float datasets.
%
%   export_data()                  % all floats found under pipeline/data
%   export_data('stale_days', 60)  % recency cut-off for the active/inactive flag
%   export_data('track_max', 300)  % max track points written per float
%
% READ-ONLY with respect to ../pipeline: this function only LOADS
% pipeline/data/<id>/float_*.mat, pipeline/floats_config.csv and (for the
% next-surface prediction) the decoded nke parameter CSVs. It writes exactly one
% file: float-site/data.js.
%
% Run make_plots.py FIRST -- the figure lists in data.js are built by scanning
% float-site/assets/plots/<id>/, so the JS only ever points at PNGs that exist.
%
% Weekly refresh:
%   1) run the pipeline as usual (RUN_all_floats)
%   2) python make_plots.py
%   3) export_data            % <- this file
% index.html never changes.

opt = parse_args(varargin);

site_dir  = fileparts(mfilename('fullpath'));
if isempty(site_dir), site_dir = pwd; end
repo_root = fileparts(site_dir);
data_root = fullfile(repo_root, 'pipeline', 'data');
plots_root= fullfile(site_dir, 'assets', 'plots');
cfgfile   = fullfile(repo_root, 'pipeline', 'floats_config.csv');

if ~isfolder(data_root)
    error('export_data:noData', 'pipeline data folder not found: %s', data_root);
end

cfg = read_config(cfgfile);
ids = list_float_ids(data_root);

fprintf('\n===== float-site: export_data =====\n');
fprintf('source : %s  (read-only)\n', data_root);
fprintf('%d float folder(s) with a saved dataset.\n\n', numel(ids));

floats = {};
for i = 1:numel(ids)
    id = ids{i};
    try
        s = build_float(id, data_root, plots_root, cfg, opt);
        floats{end+1} = s; %#ok<AGROW>
        fprintf('  %-14s %-24s %-8s %3d profiles  last %s\n', ...
            id, s.name, s.status, s.n_profiles, s.last_surface);
    catch ME
        fprintf(2, '  %-14s SKIPPED: %s\n', id, ME.message);
    end
end

if isempty(floats)
    error('export_data:empty', 'No floats could be exported.');
end

floats = sort_floats(floats);
outfile = fullfile(site_dir, 'data.js');
write_data_js(outfile, floats);

fprintf('\nwrote %s  (%d floats)\n', outfile, numel(floats));
fprintf('open index.html in a browser to view.\n');
end

% =========================================================================
function opt = parse_args(args)
opt = struct('stale_days', 45, 'track_max', 300);
if mod(numel(args), 2) ~= 0
    error('export_data:args', 'Arguments must be name/value pairs.');
end
for k = 1:2:numel(args)
    name = lower(string(args{k}));
    switch name
        case "stale_days", opt.stale_days = double(args{k+1});
        case "track_max",  opt.track_max  = double(args{k+1});
        otherwise, error('export_data:args', 'Unknown option "%s".', name);
    end
end
end

% =========================================================================
function cfg = read_config(cfgfile)
% The float registry, keyed by the (text) wmo column. Missing file is tolerated:
% the site then falls back to folder names.
cfg = table();
if ~isfile(cfgfile), warning('export_data:noConfig', 'no floats_config.csv at %s', cfgfile); return; end
copts = detectImportOptions(cfgfile, 'Delimiter', ',', 'TextType', 'string');
copts = setvartype(copts, 'wmo', 'string');
cfg = readtable(cfgfile, copts);
cfg.wmo = strip(string(cfg.wmo));
cfg = cfg(cfg.wmo ~= "" & ~ismissing(cfg.wmo), :);
end

% =========================================================================
function ids = list_float_ids(data_root)
% Every pipeline/data subfolder that holds a saved float_*.mat.
skip = {'_sbd_staging', 'share_out'};
d = dir(data_root);
ids = {};
for i = 1:numel(d)
    if ~d(i).isdir || startsWith(d(i).name, '.') || any(strcmp(d(i).name, skip))
        continue
    end
    if ~isempty(dir(fullfile(data_root, d(i).name, 'float_*.mat')))
        ids{end+1} = d(i).name; %#ok<AGROW>
    end
end
end

% =========================================================================
function s = build_float(id, data_root, plots_root, cfg, opt)
float_dir = fullfile(data_root, id);
ml = dir(fullfile(float_dir, 'float_*.mat'));
S  = load(fullfile(ml(1).folder, ml(1).name));
if ~isfield(S, 'PD') || ~istable(S.PD)
    error('no PD table in %s', ml(1).name);
end
PD = S.PD;
D  = [];
if isfield(S, 'D') && istable(S.D), D = S.D; end

row = config_row(cfg, id);

% ---- positions + time (column names vary by platform/vintage) -----------
lat = pick_col(PD, {'Latitude','Lat'});
lon = pick_col(PD, {'Longitude','Long','Lon'});
t   = pick_time(PD, {'Datetime','DatetimeSurf','DatetimeStart','Time'});

ok = ~isnan(lat) & ~isnan(lon) & ~isnat(t);
if ~any(ok), error('no positioned profiles'); end
lat = lat(ok);  lon = lon(ok);  t = t(ok);
[t, ord] = sort(t);  lat = lat(ord);  lon = lon(ord);

% ---- headline numbers ---------------------------------------------------
% Status and position come from EVERY fix -- the last transmission is the last
% transmission, whatever the map-framing filter thinks of it.
n_profiles = count_ascent_profiles(D, PD);
last_t     = t(end);
depl_t     = deployment_time(D, t);
days_since = days(datetime('now') - last_t);

[ns, ns_src] = next_surface(float_dir, id, row, PD, t);

% ---- region + status ----------------------------------------------------
region = region_of(lat(end), lon(end), row);
if days_since > opt.stale_days
    status = 'inactive';
    status_note = sprintf('no transmission for %d days', round(days_since));
    ns = '';  ns_src = '';      % a "next surfacing" for a float that stopped
    status_note = [status_note, ' — no next surfacing predicted'];
else
    status = 'active';
    status_note = '';
end

% ---- figures (scan what make_plots.py actually produced) ----------------
[traj, graphs] = figure_lists(plots_root, id);

% ---- assemble -----------------------------------------------------------
s = struct();
s.id             = id;
s.wmo            = char(getfield_or(row, 'wmo', id));
s.name           = char(getfield_or(row, 'name', id));
s.platform       = char(getfield_or(row, 'platform', ''));
s.sensors        = char(getfield_or(row, 'sensors', ''));
s.region         = region;
s.status         = status;
s.status_note    = status_note;
s.latitude       = round(lat(end), 4);
s.longitude      = round(lon(end), 4);
s.location       = latlon_str(lat(end), lon(end));
s.deployment_date= datestr(depl_t, 'yyyy-mm-dd');
s.last_surface   = datestr(last_t, 'yyyy-mm-dd HH:MM');
s.days_since     = round(days_since, 1);
s.next_surface   = ns;
s.next_surface_source = ns_src;
s.n_profiles     = n_profiles;
% The TRACK (and only the track) hides far-outlier pre-deployment fixes, so the
% map frames the deployment area instead of stretching back to the workshop.
kt = drop_outliers(lat, lon);
s.track          = decimate_track(lat(kt), lon(kt), opt.track_max);
s.trajectory     = traj;
s.graphs         = graphs;
s.notes          = char(getfield_or(row, 'notes', ''));
end

% =========================================================================
function row = config_row(cfg, id)
% The config row whose wmo matches this folder id ([] if none / no config).
row = [];
if isempty(cfg) || ~ismember('wmo', cfg.Properties.VariableNames), return; end
hit = find(strcmpi(cfg.wmo, string(id)), 1);
if isempty(hit), return; end
row = table2struct(cfg(hit, :));
end

function v = getfield_or(row, name, dflt)
v = dflt;
if isempty(row) || ~isfield(row, name), return; end
x = row.(name);
if isnumeric(x) && isscalar(x) && isnan(x), return; end
x = strip(string(x));
if x == "" || ismissing(x) || strcmpi(x, "nan"), return; end
v = x;
end

% =========================================================================
function v = pick_col(T, names)
% First present column out of `names`, as a double column (NaN column if none).
for k = 1:numel(names)
    if ismember(names{k}, T.Properties.VariableNames)
        v = double(T.(names{k}));  v = v(:);  return
    end
end
v = nan(height(T), 1);
end

function t = pick_time(T, names)
% First present datetime column out of `names` (NaT column if none).
for k = 1:numel(names)
    if ismember(names{k}, T.Properties.VariableNames)
        x = T.(names{k});
        if isdatetime(x), t = x(:); return; end
    end
end
t = NaT(height(T), 1);
end

% =========================================================================
function n = count_ascent_profiles(D, PD)
% Number of ASCENT profiles (stage 590). Falls back to the per-profile table
% when the sample table has no stage column.
n = 0;
if ~isempty(D) && ismember('Stage', D.Properties.VariableNames)
    pn = pick_col(D, {'Profile_no','Profile'});
    st = double(D.Stage);
    m  = st == 590 & ~isnan(pn);
    if any(m), n = numel(unique(pn(m))); return; end
end
pn = pick_col(PD, {'Profile_no','Profile'});
pn = pn(~isnan(pn));
if ~isempty(pn), n = numel(unique(pn)); end
end

% =========================================================================
function t0 = deployment_time(D, t)
% Deployment = the first ASCENT profile in the water (stage 590, cycle >= 1).
% Using the profile record rather than the first GPS fix keeps pre-deployment
% workshop/test transmissions out of the deployment date without any heuristic.
t0 = t(1);
if isempty(D) || ~ismember('Stage', D.Properties.VariableNames), return; end
dt = pick_time(D, {'Datetime','DatetimeSurf','DatetimeStart','Time'});
pn = pick_col(D, {'Profile_no','Profile'});
m  = double(D.Stage) == 590 & pn >= 1 & ~isnat(dt);
if any(m), t0 = min(dt(m)); end
end

% =========================================================================
function keep = drop_outliers(lat, lon)
% Same rule as plot_float's map: single-linkage spatial clustering (longitude
% scaled by cos(lat)); keep the largest cluster when the rest are a clear
% minority, otherwise keep everything.
keep = true(size(lat));
n = numel(lat);
if n < 4, return; end
lat = lat(:);  lon = lon(:);
cw = max(cosd(median(lat, 'omitnan')), 0.2);
Dm = hypot(lat - lat.', (lon - lon.') * cw);
Dm(1:n+1:end) = Inf;
nn = min(Dm, [], 2);
link = max(5 * median(nn, 'omitnan'), 0.5);

adj = Dm <= link;
lab = zeros(n, 1);  c = 0;
for i = 1:n
    if lab(i) == 0
        c = c + 1;  stack = i;  lab(i) = c;
        while ~isempty(stack)
            v = stack(end);  stack(end) = [];
            nb = find(adj(v, :) & (lab.' == 0));
            lab(nb) = c;  stack = [stack, nb]; %#ok<AGROW>
        end
    end
end
u = unique(lab);
counts = arrayfun(@(x) sum(lab == x), u);
[~, imax] = max(counts);
drop = lab ~= u(imax);
if any(drop) && sum(drop) <= max(3, ceil(0.30 * n))
    keep = ~drop;
end
end

% =========================================================================
function [ns, src] = next_surface(float_dir, id, row, PD, t)
% Predicted next surfacing, as a 'yyyy-mm-dd HH:MM' string ('' if unknown).
%   arvor : last surfacing + the nke cycle period (same rule plot_float uses)
%   other : last surfacing + the median interval between recent surfacings
ns = '';  src = '';
imei = char(getfield_or(row, 'imei', ''));

per = nke_cycle_hours(float_dir, id, imei, PD);
if ~isnan(per)
    ns = datestr(t(end) + hours(per), 'yyyy-mm-dd HH:MM');
    src = 'nke cycle period';
    return
end
if numel(t) >= 3
    dt = median(hours(diff(t(max(1,end-9):end))), 'omitnan');
    if isfinite(dt) && dt > 0
        ns = datestr(t(end) + hours(dt), 'yyyy-mm-dd HH:MM');
        src = 'median cycle interval';
    end
end
end

function per = nke_cycle_hours(float_dir, id, imei, PD)
% Cycle period (hours) from "<id>_Float parameters Message 1.csv": MC2 while the
% cycle number is within MC1, MC3 afterwards. NaN when the file/fields are absent.
per = NaN;
fp = find_float_csv(float_dir, imei, id, 'Float parameters Message 1');
if isempty(fp), return; end
try
    opts = setvartype(detectImportOptions(fp, 'Delimiter', ';'), 'string');
    T    = readtable(fp, opts);
    lab  = string(T{:,1});
    lastnum = @(key) last_valid_num(T{contains(lab, key), 2:end});
    mc1 = lastnum('Nb of cycles for Period 1');
    mc2 = lastnum('Cycle Period 1');
    mc3 = lastnum('Cycle Period 2');
    if isnan(mc2), return; end
    cur = max(pick_col(PD, {'Profile_no','Profile'}), [], 'omitnan');
    per = mc2;
    if ~isnan(mc1) && ~isnan(mc3) && cur > mc1, per = mc3; end
catch
    per = NaN;
end
end

function fp = find_float_csv(float_dir, imei, id, name)
% Decoded CSV in raw\, or the _sbd_staging Unit_<imei> folder. '' if neither.
fp = fullfile(float_dir, 'raw', [char(id) '_' name '.csv']);
if isfile(fp), return; end
imei = char(string(imei));
if ~isempty(imei) && ~strcmpi(imei, 'nan')
    alt = fullfile(fileparts(float_dir), '_sbd_staging', ['Unit_' imei], [char(id) '_' name '.csv']);
    if isfile(alt), fp = alt; return; end
end
fp = '';
end

function x = last_valid_num(row)
x = NaN;  row = string(row(:));
for k = numel(row):-1:1
    v = str2double(row(k));
    if ~isnan(v), x = v; return; end
end
end

% =========================================================================
function r = region_of(lat, lon, row)
% Which map a float belongs on. Latitude-based (everything from the Denmark
% Strait northward is "greenland"), overridable per float via a `region` column
% in floats_config.csv.
r = char(getfield_or(row, 'region', ''));
if ~isempty(r), r = lower(r); return; end
if lat >= 60, r = 'greenland'; else, r = 'denmark'; end
end

function s = latlon_str(lat, lon)
if lat >= 0, ns = 'N'; else, ns = 'S'; end
if lon >= 0, ew = 'E'; else, ew = 'W'; end
s = sprintf('%.3f%s %s, %.3f%s %s', abs(lat), char(176), ns, abs(lon), char(176), ew);
end

% =========================================================================
function tr = decimate_track(lat, lon, nmax)
% Track as an Nx2 [lat lon] array, thinned to at most nmax points (the last
% fix is always kept so the track ends where the marker sits).
n = numel(lat);
if n > nmax
    idx = unique([round(linspace(1, n, nmax)), n]);
else
    idx = 1:n;
end
tr = [round(lat(idx), 4), round(lon(idx), 4)];
end

% =========================================================================
function [traj, graphs] = figure_lists(plots_root, id)
% Scan float-site/assets/plots/<id>/ and split it into the trajectory figure and
% the labelled graph list. Only files that exist are listed.
traj = '';  graphs = {};
pdir = fullfile(plots_root, id);
if ~isfolder(pdir), return; end

png = dir(fullfile(pdir, '*.png'));
names = sort(string({png.name}));

fleet = {};  profs = {};
for k = 1:numel(names)
    nm  = char(names(k));
    rel = ['assets/plots/' id '/' nm];
    if contains(nm, '_map.') && isempty(traj)
        traj = rel;  continue
    end
    entry = struct('label', label_for(nm), 'src', rel);
    if contains(nm, '_profile_')
        profs{end+1} = entry; %#ok<AGROW>
    else
        fleet{end+1} = entry; %#ok<AGROW>
    end
end
graphs = [fleet, profs];   % fleet overviews first, then recent profiles
end

function lab = label_for(nm)
% Human label from the figure filename.
pre = '';
if startsWith(nm, 'gdac_'), pre = 'GDAC · ';  nm = extractAfter(nm, 'gdac_'); end
tok = regexp(nm, '_profile_(\d+)_(\d{4}-\d{2}-\d{2})', 'tokens', 'once');
if ~isempty(tok)
    lab = [pre 'Profile ' char(tok{1}) '  (' char(tok{2}) ')'];
elseif contains(nm, '_sections.')
    lab = [pre 'Depth vs time'];
elseif contains(nm, '_profiles.')
    lab = [pre 'Ascent profiles & T-S'];
elseif contains(nm, '_map.')
    lab = [pre 'Trajectory'];
else
    [~, base] = fileparts(nm);
    lab = [pre strrep(base, '_', ' ')];
end
end

% =========================================================================
function out = sort_floats(floats)
% Greenland floats first, then Denmark/Baltic; active before inactive; then name.
key = strings(numel(floats), 1);
for i = 1:numel(floats)
    f = floats{i};
    key(i) = sprintf('%d_%d_%s', ~strcmp(f.region,'greenland'), ...
                     ~strcmp(f.status,'active'), lower(f.name));
end
[~, ord] = sort(key);
out = floats(ord);
end

% =========================================================================
function write_data_js(outfile, floats)
% data.js = a plain JS assignment, so index.html works from file:// with no
% server and no fetch().
body = jsonencode(floats, 'PrettyPrint', true);

L = strings(0,1);
L(end+1) = "// float-site data -- GENERATED by export_data.m, do not edit by hand.";
L(end+1) = "// Rebuild weekly:  python make_plots.py  &&  matlab -batch export_data";
L(end+1) = "//";
L(end+1) = "// Each entry:";
L(end+1) = "//   id, wmo, name, platform, sensors   identity (id = pipeline/data folder)";
L(end+1) = "//   region        'greenland' | 'denmark'   -> which map the marker goes on";
L(end+1) = "//   status        'active' | 'inactive'     -> marker colour + table badge";
L(end+1) = "//   status_note   why it is inactive ('' when active)";
L(end+1) = "//   latitude, longitude, location          latest fix";
L(end+1) = "//   deployment_date, last_surface, days_since, next_surface";
L(end+1) = "//   next_surface_source  how next_surface was predicted";
L(end+1) = "//   n_profiles    ascent profiles (stage 590) only";
L(end+1) = "//   track         [[lat, lon], ...] thinned trajectory";
L(end+1) = "//   trajectory    path to the map PNG ('' if none)";
L(end+1) = "//   graphs        [{label, src}, ...] figures for the fold-out";
L(end+1) = "//   notes         free text from floats_config.csv";
L(end+1) = "";
L(end+1) = "const floatUpdated = """ + string(datestr(now, 'yyyy-mm-dd HH:MM')) + """;";
L(end+1) = "";
L(end+1) = "const floatData = " + string(body) + ";";
L(end+1) = "";

fid = fopen(outfile, 'w', 'n', 'UTF-8');
if fid < 0, error('export_data:write', 'cannot write %s', outfile); end
c = onCleanup(@() fclose(fid));
fprintf(fid, '%s\n', L);
end
