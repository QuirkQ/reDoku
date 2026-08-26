def sample_cloud
  [[[300, 400], [340, 440], [340, 480]]]
end

assert('the recorder walks 1..9 and asks for each in turn') do
  r = Redoku::Recorder.new(rounds: 2)
  assert_equal 1, r.wanted
  r.accept(sample_cloud)
  assert_equal 2, r.wanted
end

assert('the recorder finishes after rounds x 9 samples') do
  r = Redoku::Recorder.new(rounds: 2)
  18.times { r.accept(sample_cloud) }
  assert_true r.done?
  assert_equal 18, r.samples.size
end

assert('a recorded file round-trips through the codec') do
  r = Redoku::Recorder.new(rounds: 1)
  9.times { r.accept(sample_cloud) }
  text = r.to_text
  back = Redoku::Recorder.parse(text)
  assert_equal r.samples.size, back.size
  assert_equal r.samples[0][0], back[0][0]
  assert_equal r.samples[0][1], back[0][1]
end

assert('a corrupt line is skipped, not fatal') do
  back = Redoku::Recorder.parse("1\t10,10 20,20\nnonsense\n2\t30,30 40,40\n")
  assert_equal 2, back.size
end
