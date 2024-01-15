function [nframes,matrix,res,timeres,VENC,area_val,diam_val,flowPerHeartCycle_val, ...
    maxVel_val,PI_val,RI_val,flowPulsatile_val,velMean_val, ...
    VplanesAllx,VplanesAlly,VplanesAllz,Planes,branchList,segment,r, ...
    timeMIPcrossection,segmentFull,vTimeFrameave,MAGcrossection, imageData, ...
    bnumMeanFlow,bnumStdvFlow,StdvFromMean,segmentFullEx,autoFlow,pixelSpace, VoxDims, PIvel_val] = loadDCM(directory,handles)
% loadDCM loads dicom files and then processes them.
%
% It retursn to much to discuss, but it basically passes through all the
% processed data to paramMap.
%
% Outputs: Everything
%
% Used by: autoCollectFlow.m, and any separate functions to compute any
% saved data (PITC codes, Damping codes etc)
%
% Dependencies: ShuffleDCM.m and all QVT processing codes
%% Initialization
clc
BGPCdone=0; %0=do backgroun correction, 1=don't do background correction.
VENC = 800; %may change depending on participant
autoFlow=1; %if you want automatically extracted BC's and flow profiles 0 if not.
res='1.4';%'0.5'; %Only needed if you have multiple resolutions in your patient folder 
% AND the resolution is named in the file folder as "0.5" or 05. Put in
% with a dot here.
Vendor='GE'; %Can also put GE
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%% Don't change below %%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%Or do
addpath(pwd)

set(handles.TextUpdate,'String','Loading .DCM Data'); drawnow;
cd(directory)
%directory
[Anatpath,APpath,LRpath,SIpath] = retFlowFolders(directory,Vendor,res);
%whos APpath
%%
%Load each velocity and put into phase matrix
[VAP,~] = shuffleDCM(APpath,directory,0);
[a,c,b,d]=size(VAP);
v=zeros([a,c,b,3,d],'single');
v(:,:,:,1,:)=squeeze(VAP(:,:,:,:));
clear VAP
set(handles.TextUpdate,'String','Loading .DCM Data 20%'); drawnow;
[VLR,~] = shuffleDCM(LRpath,directory,0);
v(:,:,:,2,:)=squeeze(VLR(:,:,:,:));
clear VLR
set(handles.TextUpdate,'String','Loading .DCM Data 40%'); drawnow;
[VSI,~] = shuffleDCM(SIpath,directory,0);
v(:,:,:,3,:)=squeeze(VSI(:,:,:,:));
clear VSI
set(handles.TextUpdate,'String','Loading .DCM Data 60%'); drawnow;

% Convert to velocity
v = (2 * (v-(-VENC))/(VENC-(-VENC)) - 1) * VENC; %range values to VENCs
vMean = mean(v,5);
clear maxx minn
set(handles.TextUpdate,'String','Loading .DCM Data 80%'); drawnow;

%Load MAGnitude image
[MAG,dcminfo] = shuffleDCM(Anatpath,directory,0);
MAG = mean(MAG,4);
%MAG=imrotate(MAG(:,:,:),rotImAngle);
set(handles.TextUpdate,'String','Loading .DCM Data 100%'); drawnow;

filetype = 'dcm';
nframes = dcminfo.CardiacNumberOfImages; %number of reconstructed frames
timeres = dcminfo.NominalInterval/nframes; %temporal resolution (ms)
res = dcminfo.PixelSpacing(1); %spatial res (mm) (ASSUMED ISOTROPIC)
if strcmp('GE',Vendor)
    slicespace=dcminfo.SpacingBetweenSlices;
elseif strcmp('Siemens',Vendor)
    slicespace=dcminfo.SliceThickness;
end
matrix(1) = dcminfo.Rows; %number of pixels in rows
matrix(2) = dcminfo.Columns;
matrix(3) = length(MAG(1,1,:)); %number of slices
VoxDims=[res res slicespace];
%% Import Complex Difference
set(handles.TextUpdate,'String','Loading Complex Difference Data'); drawnow;
timeMIP = calc_angio(MAG, vMean, VENC);

%% Manual Background Phase Correction (if necessary)
back = zeros(size(vMean),'single');
if ~BGPCdone
    set(handles.TextUpdate,'String','Phase Correction with Polynomial'); drawnow;
    [poly_fitx,poly_fity,poly_fitz] = background_phase_correction(MAG,vMean(:,:,:,1),vMean(:,:,:,2),vMean(:,:,:,3));
    disp('Correcting data with polynomial');
    xrange = single(linspace(-1,1,size(MAG,1)));
    yrange = single(linspace(-1,1,size(MAG,2)));
    zrange = single(linspace(-1,1,size(MAG,3)));
    [Y,X,Z] = meshgrid(yrange,xrange,zrange);
    % Get poly data and correct average velocity for x,y,z dimensions
    back(:,:,:,1) = single(evaluate_poly(X,Y,Z,poly_fitx));
    back(:,:,:,2) = single(evaluate_poly(X,Y,Z,poly_fity));
    back(:,:,:,3) = single(evaluate_poly(X,Y,Z,poly_fitz));
    vMean = vMean - back;
    for f=1:nframes
        v(:,:,:,:,f) = v(:,:,:,:,f) - back;
    end 
    clear X Y Z poly_fitx poly_fity poly_fitz xrange yrange zrange
end

%% Find optimum global threshold for total branch segmentation
set(handles.TextUpdate,'String','Segmenting and creating Tree'); drawnow;
step = 0.001; %step size for sliding threshold
UPthresh = 0.8; %max upper threshold when creating Sval curvature plot
SMf = 10;
shiftHM_flag = 1; %flag to shift max curvature by FWHM
medFilt_flag = 1; %flag for median filtering of CD image
[~,segment] = slidingThreshold(timeMIP,step,UPthresh,SMf,shiftHM_flag,medFilt_flag);
areaThresh = round(sum(segment(:)).*0.005); %minimum area to keep
conn = 6; %connectivity (i.e. 6-pt)
segment = bwareaopen(segment,areaThresh,conn); %inverse fill holes
% save raw (cropped) images to imageData structure (for Visual Tool)
imageData.MAG = MAG;
imageData.CD = timeMIP; 
imageData.V = vMean;
imageData.Segmented = segment;
imageData.Header = dcminfo;

%% Feature Extraction
% Get trim and create the centerline data
sortingCriteria = 3; %sorts branches by junctions/intersects 
spurLength = 8; %minimum branch length (removes short spurs)
[~,~,branchList,~] = feature_extraction(sortingCriteria,spurLength,vMean,segment,handles);

%% You can load another segmentation here if you want which will overlap on images
Exseg=segment; %for now, dummy copy, can do feature extraction
%[~,~,branchList2,~] = feature_extraction(sortingCriteria,spurLength,vMean,logical(JSseg),[]);

%% SEND FOR PROCESSING
% Flow parameter calculation, bulk of code is in paramMap_parameters.m
SEG_TYPE = 'thresh'; %kmeans or thresh
if strcmp(SEG_TYPE,'kmeans')
    [area_val,diam_val,flowPerHeartCycle_val,maxVel_val,PI_val,RI_val,flowPulsatile_val,...
        velMean_val,VplanesAllx,VplanesAlly,VplanesAllz,r,timeMIPcrossection,segmentFull,...
        vTimeFrameave,MAGcrossection,bnumMeanFlow,bnumStdvFlow,StdvFromMean,Planes] ...
        = paramMap_params_kmeans(filetype,branchList,matrix,timeMIP,vMean, ...
    back,BGPCdone,directory,nframes,res,MAG,handles, v,slicespace);
elseif strcmp(SEG_TYPE,'thresh')
    [area_val,diam_val,flowPerHeartCycle_val,maxVel_val,PI_val,RI_val,flowPulsatile_val,...
        velMean_val,VplanesAllx,VplanesAlly,VplanesAllz,r,timeMIPcrossection,segmentFull,...
        vTimeFrameave,MAGcrossection,bnumMeanFlow,bnumStdvFlow,StdvFromMean,Planes,pixelSpace,...
        segmentFullEx,PIvel_val] ...
        = paramMap_params_threshS(filetype,branchList,matrix,timeMIP,vMean, ...
    back,BGPCdone,directory,nframes,res,MAG,handles, v,slicespace,Exseg);
else
    disp("Incorrect segmentation type selected, please select 'kmeans' or 'thresh'");
end 
set(handles.TextUpdate,'String','All Data Loaded'); drawnow;
return