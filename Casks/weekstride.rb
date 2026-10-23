cask "weekstride" do
  version "0.8.1,67"
  sha256 "f838c11395f781cdf4477efd06f81330331d1d5a8ebab80555ad7fd1c3196c9d"

  url "https://github.com/zhutong1998/weekstride/releases/download/v#{version.csv.first}/weekstride-#{version.csv.first}-#{version.csv.second}-macos-arm64.zip"
  name "WeekStride"
  name "周程"
  desc "Weekly task planner with local storage"
  homepage "https://github.com/zhutong1998/weekstride"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "WeekStride.app"
end
