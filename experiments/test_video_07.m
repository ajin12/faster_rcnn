function script_faster_rcnn_demo()
close all;
clc;
clear mex;
clear is_valid_handle; % to clear init_key
run(fullfile(fileparts(fileparts(mfilename('fullpath'))), 'startup'));
%% -------------------- CONFIG --------------------
opts.caffe_version          = 'caffe_faster_rcnn';
opts.gpu_id                 = auto_select_gpu;
active_caffe_mex(opts.gpu_id, opts.caffe_version);

opts.per_nms_topN           = 6000;
opts.nms_overlap_thres      = 0.7;
opts.after_nms_topN         = 300;
opts.use_gpu                = true;

opts.test_scales            = 600;

%% -------------------- INIT_MODEL --------------------
%model_dir                   = fullfile(pwd, 'output', 'faster_rcnn_final', 'faster_rcnn_VOC2007_vgg_16layers'); %% VGG-16
%model_dir                   = fullfile(pwd, 'output', 'faster_rcnn_final', 'faster_rcnn_VOC0712_ZF'); %% ZF
model_dir                   = fullfile(pwd, 'output', 'faster_rcnn_final', 'faster_rcnn_VOC2007_vgg_16layers'); %% VGG-16
proposal_detection_model    = load_proposal_detection_model(model_dir);

proposal_detection_model.conf_proposal.test_scales = opts.test_scales;
proposal_detection_model.conf_detection.test_scales = opts.test_scales;
if opts.use_gpu
    proposal_detection_model.conf_proposal.image_means = gpuArray(proposal_detection_model.conf_proposal.image_means);
    proposal_detection_model.conf_detection.image_means = gpuArray(proposal_detection_model.conf_detection.image_means);
end

% caffe.init_log(fullfile(pwd, 'caffe_log'));
% proposal net
rpn_net = caffe.Net(proposal_detection_model.proposal_net_def, 'test');
rpn_net.copy_from(proposal_detection_model.proposal_net);
% fast rcnn net
fast_rcnn_net = caffe.Net(proposal_detection_model.detection_net_def, 'test');
fast_rcnn_net.copy_from(proposal_detection_model.detection_net);

% set gpu/cpu
if opts.use_gpu
    caffe.set_mode_gpu();
else
    caffe.set_mode_cpu();
end       

%% -------------------- WARM UP --------------------
% the first run will be slower; use an empty image to warm up

for j = 1:2 % we warm up 2 times
    im = uint8(ones(375, 500, 3)*128);
    if opts.use_gpu
        im = gpuArray(im);
    end
    [boxes, scores]             = proposal_im_detect(proposal_detection_model.conf_proposal, rpn_net, im);
    aboxes                      = boxes_filter([boxes, scores], opts.per_nms_topN, opts.nms_overlap_thres, opts.after_nms_topN, opts.use_gpu);
    if proposal_detection_model.is_share_feature
        [boxes, scores]             = fast_rcnn_conv_feat_detect(proposal_detection_model.conf_detection, fast_rcnn_net, im, ...
            rpn_net.blobs(proposal_detection_model.last_shared_output_blob_name), ...
            aboxes(:, 1:4), opts.after_nms_topN);
    else
        [boxes, scores]             = fast_rcnn_im_detect(proposal_detection_model.conf_detection, fast_rcnn_net, im, ...
            aboxes(:, 1:4), opts.after_nms_topN);
    end
end

%% -------------------- TESTING --------------------
%im_names = {'001763.jpg', '004545.jpg', '000542.jpg', '000456.jpg', '001150.jpg'};
% these images can be downloaded with fetch_faster_rcnn_final_model.m
% im_names = {'01_frame0044.jpg', '01_frame0055.jpg', '01_frame0377.jpg', '01_frame0403.jpg', '01_frame0412.jpg'}; % CHANGED
%im_names = {'01_frame0044.jpg'}; % CHANGED
%im_names = {'08_frame0015.jpg'}; % CHANGED
num_annot = 1; %added
%frames = dir(strcat(pwd, '/test_input_aj/HighlyRatedTrimResize/*.jpg')); % ADDED, frames is structure array with fields name, date, bytes, isdir

frames = dir(strcat(pwd, '/test_input_aj/m2cai16-tool/tool_video_07/*.jpg')); % ADDED, frames is structure array with fields name, date, bytes

im_names = {frames.name}; % ADDED, cell array of strings
% im_names = {'Image1000.jpg'}; % CHANGED

running_time = [];
for j = 1:length(im_names)
    
%   im = imread(fullfile(strcat(pwd, '/datasets/imageset'), im_names{j})); % CHANGED pwd part
%    im = imread(fullfile(strcat(pwd, '/test_input_aj/HighlyRatedTrimResize'), im_names{j})); % CHANGED pwd part
    im = imread(fullfile(strcat(pwd, '/test_input_aj/m2cai16-tool/tool_video_07'), im_names{j})); % CHANGED pwd part
    
    if opts.use_gpu
        im = gpuArray(im);
    end
    
    % test proposal
    th = tic();
    [boxes, scores]             = proposal_im_detect(proposal_detection_model.conf_proposal, rpn_net, im);
    t_proposal = toc(th);
    th = tic();
    aboxes                      = boxes_filter([boxes, scores], opts.per_nms_topN, opts.nms_overlap_thres, opts.after_nms_topN, opts.use_gpu);
    t_nms = toc(th);
    
    % test detection
    th = tic();
    if proposal_detection_model.is_share_feature
        [boxes, scores]             = fast_rcnn_conv_feat_detect(proposal_detection_model.conf_detection, fast_rcnn_net, im, ...
            rpn_net.blobs(proposal_detection_model.last_shared_output_blob_name), ...
            aboxes(:, 1:4), opts.after_nms_topN);
    else
        [boxes, scores]             = fast_rcnn_im_detect(proposal_detection_model.conf_detection, fast_rcnn_net, im, ...
            aboxes(:, 1:4), opts.after_nms_topN);
    end
    t_detection = toc(th);
    
    fprintf('%s (%dx%d): time %.3fs (resize+conv+proposal: %.3fs, nms+regionwise: %.3fs)\n', im_names{j}, ...
        size(im, 2), size(im, 1), t_proposal + t_nms + t_detection, t_proposal, t_nms+t_detection);
    running_time(end+1) = t_proposal + t_nms + t_detection;
    
    % visualize
    classes = proposal_detection_model.classes;
    boxes_cell = cell(length(classes), 1);
    %thres = 0.6;
    thres = 0.5; % 4/27/2017 Use threshold 0.5 for testing
    %thres = 0.00001; % CHANGED for m2cai16-tool test (was 0.0 for 8Classes test)
    %thres = 0.8; % 2/8/2017  Use threshold 0.8 for testing
    %thres = 0.9; 
    for i = 1:length(boxes_cell)
        boxes_cell{i} = [boxes(:, (1+(i-1)*4):(i*4)), scores(:, i)];
        boxes_cell{i} = boxes_cell{i}(nms(boxes_cell{i}, 0.3), :);
        
        I = boxes_cell{i}(:, 5) >= thres;
        boxes_cell{i} = boxes_cell{i}(I, :);
        filename = im_names{j}; %added
        coord = boxes_cell{i}; %added
        type = classes{i}; %added
        annot3(num_annot) = struct('seq', j, ... 
                                       'frame', filename, ... 
                                       'coord', coord, ...
                                       'class', type); %added
        num_annot = num_annot+1; %added
        
    end
    figure(j); 
    showboxes(im, boxes_cell, classes, 'voc');
    % gcf - gets the current figure handle. Save jpg encountered error: didn't draw bounding box around tool. Drew box around whole image.
    % saveas(gcf, strcat('/home/ajin/faster_rcnn/test_output_aj/', im_names{j}, '_result.jpg')); % ADDED
%    savefig(strcat('/home/ajin/faster_rcnn/test_output_aj/HighlyRatedTrimResize/', im_names{j}(1:end-4), '_result.fig')) % ADDED
%    fig=openfig(strcat('/home/ajin/faster_rcnn/test_output_aj/HighlyRatedTrimResize/', im_names{j}(1:end-4), '_result.fig'),'new','invisible');
 %   saveas(fig,strcat('/home/ajin/faster_rcnn/test_output_aj/HighlyRatedTrimResize/', im_names{j}(1:end-4), '_result.jpg'),'jpg')


    savefig(strcat('/home/ajin/faster_rcnn/test_output_aj/m2cai16-tool/tool_video_07/', im_names{j}(1:end-4), '_result.fig')) % ADDED
    fig=openfig(strcat('/home/ajin/faster_rcnn/test_output_aj/m2cai16-tool/tool_video_07/', im_names{j}(1:end-4), '_result.fig'),'new','invisible');
    saveas(fig,strcat('/home/ajin/faster_rcnn/test_output_aj/m2cai16-tool/tool_video_07/', im_names{j}(1:end-4), '_result.jpg'),'jpg')

    close(fig);
    pause(0.1);
end
    annot_filename = strcat('tool_video_07_image', '_test.csv'); %added
    writetable(struct2table(annot3), strcat('/home/ajin/faster_rcnn/test_output_aj/m2cai16-tool/tool_video_07/', annot_filename)); %added
fprintf('mean time: %.3fs\n', mean(running_time));

caffe.reset_all(); 
clear mex;

end

function proposal_detection_model = load_proposal_detection_model(model_dir)
    ld                          = load(fullfile(model_dir, 'model'));
    proposal_detection_model    = ld.proposal_detection_model;
    clear ld;
    
    proposal_detection_model.proposal_net_def ...
                                = fullfile(model_dir, proposal_detection_model.proposal_net_def);
    proposal_detection_model.proposal_net ...
                                = fullfile(model_dir, proposal_detection_model.proposal_net);
    proposal_detection_model.detection_net_def ...
                                = fullfile(model_dir, proposal_detection_model.detection_net_def);
    proposal_detection_model.detection_net ...
                                = fullfile(model_dir, proposal_detection_model.detection_net);
    
end

function aboxes = boxes_filter(aboxes, per_nms_topN, nms_overlap_thres, after_nms_topN, use_gpu)
    % to speed up nms
    if per_nms_topN > 0
        aboxes = aboxes(1:min(length(aboxes), per_nms_topN), :);
    end
    % do nms
    if nms_overlap_thres > 0 && nms_overlap_thres < 1
        aboxes = aboxes(nms(aboxes, nms_overlap_thres, use_gpu), :);       
    end
    if after_nms_topN > 0
        aboxes = aboxes(1:min(length(aboxes), after_nms_topN), :);
    end
end
