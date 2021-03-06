%
%  Attentional Correlation Filter Network for Adaptive Visual Tracking
%
%  Jongwon Choi, 2017
%  https://sites.google.com/site/jwchoivision/  
% 
%  MATLAB code for correlation filter network
%  When you use this code for your research, please refer the below references.
%  You can't use this code for any commercial purpose without author's
%  agreement.
%  If you have any question or comment, please contact to
%  jwchoi.pil@gmail.com.
%  
% 
%
%  Reference:
%  [1] J. Choi, et al., "Attentional Correlation Filter Network for Adaptive Visual Tracking", CVPR2017
%  [2] J. Choi, et al., "Visual Tracking Using Attention-Modulated Disintegration and Integration", CVPR2016


function [positions, time] = tracker(video_path, img_files, pos, target_sz, ...
    padding, kernel, lambda, output_sigma_factor, interp_factor, cell_size, ...
    features, show_visualization, conn)

% Parameters
feature_vector = {'color', 'hog'};
kernel_vector = {'gaussian', 'polynomial'};
scale_vector = [-2, -1, 1, 2];
hierarchy_vector = [1,2,3,4,5];
resize_min_size = 40;
lambda_r = 0.7;
N_r = 30;

% auto-setting
n_feature = length(feature_vector);
n_kernel = length(kernel_vector);
n_scale = length(scale_vector);
n_hierarchy = length(hierarchy_vector);
max_hierarchy = max(hierarchy_vector);

x_scale_vector = [0.0, scale_vector, zeros(1, n_scale), scale_vector];
y_scale_vector = [0.0, zeros(1, n_scale), scale_vector, scale_vector];

avg_conf = 0;

% for fast fft algorithm
fftw('planner');

%image resize
resize_factor = resize_min_size / min(target_sz);
target_sz = floor(target_sz * resize_factor);
pos = round(pos * resize_factor);

%window size, taking padding into account
window_sz = floor(target_sz * (1 + padding));
init_window_sz = window_sz;

% variables for redetection algorithm
b_redetect = 0;
redetect_attVec = zeros([n_feature*n_kernel, 3*n_scale+1, n_hierarchy+1]);
redetect_attVec(:, 1, 1) = 1;

%create regression labels, gaussian shaped, with a bandwidth
%proportional to target size
output_sigma = sqrt(prod(target_sz)) * output_sigma_factor / cell_size;
yf = fft2(gaussian_shaped_labels(output_sigma, floor(init_window_sz / cell_size)));

yf_cell = cell(size(yf));
for ii = 1:size(yf_cell,1)
    for jj = 1:size(yf_cell,2)        
        yf_cell{ii,jj} = gaussian_shaped_labels2(output_sigma, floor(init_window_sz / cell_size), [ii-1, jj-1]);
    end
end

%store pre-computed cosine window
cos_window2 = (hann(size(yf,1)) * hann(size(yf,2))');

% initial mask for AtCF
mask = ones(size(yf,1), size(yf,2));
depthBoundaryX = max(round(size(yf,2)/(1 + padding)), 3);
depthBoundaryY = max(round(size(yf,1)/(1 + padding)), 3);
mask( depthBoundaryY:(end-depthBoundaryY+1), depthBoundaryX:(end-depthBoundaryX+1) ) = 0;

if show_visualization,  %create video interface
    update_visualization = show_video(img_files, video_path);
end

%SOCKET CONNECT
b_start_pred = -1;
attention_vec = [];
b_occ = 0;

%note: variables ending with 'f' are in the Fourier domain.
time = 0;  %to calculate FPS
positions = zeros(numel(img_files), 4);

% tracking module initialization & setting
filterPool = repmat(struct('model_dalphaf', [], 'model_xf', [], 'featureType', [], ...
    'kernelType', [], 'xScale', 1.0, 'yScale', 1.0, 'timeStep', 1, 'check', 0, ...
    'confidence', [], 'forward_pos', [], 'ws',[],'idxs',[],'ws2',[],'idxs2',[],'response',[]),...
    [n_feature*n_kernel, (3*n_scale+1), max_hierarchy+1]);
for i = 1:n_kernel
    [filterPool(i:n_kernel:end, :, :).kernelType] = deal(kernel_vector{i});
end
for i = 1:n_feature
    [filterPool(((i-1)*n_kernel+1):(i*n_kernel), :, :).featureType] = deal(feature_vector{i});
end
for i = 1:length(x_scale_vector)
    [filterPool(:,i,:).xScale] = deal(x_scale_vector(i));
    [filterPool(:,i,:).yScale] = deal(y_scale_vector(i));
end
for i = 1:(max_hierarchy+1)
    [filterPool(:,:,i).timeStep] = deal(i);
end


% Run tracker
for frame = 1:numel(img_files),
    
    %load image
    im = imread([video_path img_files{frame}]);
    im = imresize(im, resize_factor);
    if size(im,3) > 1,
        im_gray = rgb2gray(im);
    else
        im_gray = im;
    end
    
    tic()
    
    % initialization (w/ first frame)
    if frame == 1,
        %feature extraction
        patch_gray = get_subwindow(im_gray, pos, init_window_sz);
        x_hog = get_features(patch_gray, features, cell_size, []);
        
        patch = get_subwindow(im, pos, init_window_sz);
        feature = single(imresize(patch, [size(x_hog,1), size(x_hog,2)]))/255;
        if(size(feature,3) > 1)
            feature = cat(3, feature, RGB2Lab(feature) / 255 + 0.5);
        else
            feature = gray_feature(feature);
        end
        x_color = feature;
        
        % [AtCF] PGDT training
        [rf, stS] = init_stSaliency(x_color, mask);
        stS = stS / max(stS(:));   
        
        % For initial frame, cos_window is used as the saliency map
        salWeight = 0.0;
        saliencyMap = cos_window2;
        
        %filter training
        xf_color = fft2(bsxfun(@times, x_color, saliencyMap));
        xf_hog = fft2(bsxfun(@times, x_hog, saliencyMap));
                
        %module-wise filter training & validation
        for ii = 1:size(filterPool,1)
            filterPool(ii,1,1) = initialize_filter(filterPool(ii,1,1), xf_hog, xf_color, kernel, lambda);
        end
                    
        
    % Test & Update     
    else
          
        % [socket] receiving the predicted scores
        recv_val = double(py.tcp_server.recv(conn));
        if(recv_val > 0)
            b_start_pred = 1;
        end
        
        % Select the attentional modules
        if(b_start_pred > 0)
            attention_vec = zeros(size(filterPool));
            attention_vec(recv_val+1) = 1;
        else
            attention_vec = ones(size(filterPool));
        end
        
        %module-wise filter test & validation
        [filterPool(:).confidence] = deal(0);
        temp_filterPool = filterPool(:,1,:);
        size_limit = (window_sz(1)+cell_size*y_scale_vector <= 2*cell_size | window_sz(2)+cell_size*x_scale_vector <= 2*cell_size);

        % For full-search case
        if(b_start_pred < 0)
            
            for jj = 1:size(filterPool,2)

                if(size_limit(jj) == 1 || sum(vec(attention_vec(:,jj,:))) == 0)
                    continue;
                end

                filterPool(:,jj,:) = filter_validation(temp_filterPool, attention_vec(:,jj,:), ...
                    im, pos, window_sz, x_scale_vector(jj), y_scale_vector(jj), ...
                    init_window_sz, hierarchy_vector, n_hierarchy, rf, cos_window2, salWeight, ...
                    cell_size, features, interp_factor, kernel, yf, yf_cell, lambda, b_occ, padding);


            end
            
        % For attention (selective) case
        else

            for jj = 1:size(filterPool,2)

                if(size_limit(jj) == 1 || sum(vec(attention_vec(:,jj,:))) == 0)
                    continue;
                end

                filterPool(:,jj,:) = filter_validation(temp_filterPool, attention_vec(:,jj,:), ...
                    im, pos, window_sz, x_scale_vector(jj), y_scale_vector(jj), ...
                    init_window_sz, hierarchy_vector, n_hierarchy, rf, cos_window2, salWeight, ...
                    cell_size, features, interp_factor, kernel, yf, yf_cell, lambda, b_occ, padding);

            end
            
        end
        
        %redetection algorithm
        if(b_redetect)
            redetect_filterPool(:,1,:) = filter_validation(redetect_filterPool(:,1,:), redetect_attVec(:,1,:), ...
                    im, redetect_pos, redetect_window_sz, 0, 0, ...
                    init_window_sz, hierarchy_vector, n_hierarchy, redetect_rf, cos_window2, salWeight, ...
                    cell_size, features, interp_factor, kernel, yf, yf_cell, lambda, b_occ, padding);                
        end
        
        
        % [socket] sending the estimated validation scores
        % For full-search case
        if(b_start_pred > 0)
            conf_stack = [filterPool(attention_vec==1).confidence];
            py.tcp_server.send(conn, single(conf_stack));
        % For selective case
        else            
            conf_stack = [filterPool.confidence];
            py.tcp_server.send(conn, single(conf_stack(1:130)));
            py.tcp_server.send(conn, single(conf_stack(131:260)));
        end
        
        % module tracker buffer                    
        prev_filterPool = filterPool;
        
        % Select the best module
        [~,idx] = max([filterPool.confidence]);
        [~, ~, idx3] = ind2sub(size(filterPool), idx);
        
        % Redetection algorithm
        if(b_redetect)
            [~,redetect_idx] = max([redetect_filterPool.confidence]);
            
            % redetection module is selected:
            if(filterPool(idx).confidence <  redetect_filterPool(redetect_idx).confidence)
                idx = redetect_idx;
                filterPool = redetect_filterPool;
                b_redetect = 0;
                rf = redetect_rf;
                window_sz = redetect_window_sz;
            end
            
            % redetection finished
            redetect_frame = redetect_frame - 1;
            if(redetect_frame < 1)
                b_redetect = 0;
            end
        end

        % Redetection start
        if(filterPool(idx).confidence < lambda_r*mean(avg_conf) && frame > N_r && b_redetect == 0)
            b_redetect = 1;
            redetect_frame = N_r;
            redetect_filterPool = filterPool;
            [redetect_filterPool.confidence] = deal(0);
            redetect_pos = pos;
            redetect_window_sz = window_sz;
            redetect_rf = rf;
        end

        % Tracking position & scale decision
        pos = filterPool(idx).forward_pos;
        window_sz = floor([window_sz(1)+cell_size*filterPool(idx).yScale, window_sz(2)+cell_size*filterPool(idx).xScale]);
        if(frame == 2)
            avg_conf = filterPool(idx).confidence;
        else
            avg_conf = (1-interp_factor)*avg_conf + interp_factor*filterPool(idx).confidence;
        end
        
        % normal filter update
        %feature extraction
        subwindow = get_subwindow(im, pos, window_sz);
        [patch,~,~] = imresize_mem(subwindow, init_window_sz, filterPool(idx).ws, filterPool(idx).idxs);
        if(size(patch,3)>1)
            patch_gray = rgb2gray(patch);
        else
            patch_gray = patch;
        end
        x_hog = get_features(patch_gray, features, cell_size, []);

        [feature,~,~] = imresize_mem(patch, [size(x_hog,1), size(x_hog,2)], filterPool(idx).ws2, filterPool(idx).idxs2);
        feature = single(feature)/255;
        if(size(feature,3) > 1)
            feature = cat(3, feature, RGB2Lab(feature) / 255 + 0.5);
        else
            feature = gray_feature(feature);
        end
        x_color = feature;

        
        % [AtCF] PGDT training
        [rf, stS] = update_stSaliency(x_color, mask, rf);
        
        % saliency map estimation
        salWeight = 0.9;        
        stS = stS .* cos_window2;         
        saliencyMap = (1-salWeight)*cos_window2 + salWeight*stS;

        % weighted feature map
        xf_color = fft2(bsxfun(@times, x_color, saliencyMap));
        xf_hog = fft2(bsxfun(@times, x_hog, saliencyMap));

        %FIFO
        filterPool(:,:,2:end) = filterPool(:,:,1:(end-1));
        for ii = 1:max_hierarchy
            [filterPool(:,:,ii).timeStep] = deal(ii);
        end

        %module-wise filter updating
        target_filterPool = filterPool(:, 1, idx3+1);
        for ii = 1:size(filterPool,1)
            filterPool(ii,1,1) = filter_update(filterPool(ii,1,1), target_filterPool(ii), xf_hog, xf_color, kernel, lambda, interp_factor);
        end
                            
        
    end
        
    %save position and time stamping
    output_pos = pos / resize_factor;
    output_sz = window_sz / resize_factor;
    positions(frame,:) = [output_pos([2,1]) - output_sz([2,1])/2/(1 + padding), output_pos([2,1]) + output_sz([2,1])/2/(1 + padding)];
    time = time + toc();
    
    %visualization (Referred from KCF code)
    if show_visualization,
        
        if(~isempty(attention_vec))
            fired_mod = zeros(size(attention_vec));
            fired_mod(idx) = 1;
            temp_att_vec = attention_vec;
            temp_att_vec(idx) = 0;
            aa = reshape(temp_att_vec, size(filterPool));
            bb = cat(2, aa(:,:,1), aa(:,:,2), aa(:,:,3), aa(:,:,4), aa(:,:,5));
            cc = reshape(fired_mod, size(filterPool));
            dd = cat(2, cc(:,:,1), cc(:,:,2), cc(:,:,3), cc(:,:,4), cc(:,:,5));
            firing_map = cat(3, dd, bb, zeros(size(bb)));
        else
            firing_map = [];
        end
        
        box = [output_pos([2,1]) - output_sz([2,1])/2/(1 + padding), output_sz([2,1])/(1 + padding)];
        stop = update_visualization(frame, box, firing_map);        
        
        if stop, break, end  %user pressed Esc, stop early
        
        drawnow
    end
    
end

end